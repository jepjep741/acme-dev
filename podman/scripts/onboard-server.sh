#!/usr/bin/env bash
# Palvelinten liittäminen jakeluun (konttiversio keskus/onboard-server.sh:sta). Ajetaan
# palvelukäyttäjänä keskuksessa; Vault-komennot ajetaan vault-kontissa ylläpitäjän tunnuksella
# (userpass + TOTP, policy onboard-admin). Token ei näy komentorivillä eikä lokeissa.
#
#   onboard-server.sh add PALVELIN IP VARMENNE...   policy cert-PALVELIN + AppRole (CIDR IP/32),
#                                                   tulostaa role_id:n ja käärityn secret_id:n
#   onboard-server.sh wrap PALVELIN                 uusi kääritty secret_id (toimitus/kierrätys)
#   onboard-server.sh rotate PALVELIN               kuten wrap + listaa vanhat secret_id:t hävitettäviksi
#   onboard-server.sh destroy-old PALVELIN          hävitä kaikki paitsi uusin secret_id (kierrätyksen jälkeen)
#   onboard-server.sh remove PALVELIN               hävitä secret_id:t, poista rooli ja policy
#   onboard-server.sh list                          palvelimet ja niiden varmenteet
#   onboard-server.sh login TIEDOSTO                kirjaudu (userpass + TOTP) ja tallenna token tiedostoon 0600
#                                                   massajakelua varten: VAULT_ADMIN_TOKEN_FILE=TIEDOSTO (TTL 1 h).
#                                                   Poista tiedosto heti ajon jälkeen (shred -u).
#   onboard-server.sh csv TIEDOSTO --out HAKEMISTO [--ca-path ca.pem] [--dvv-ca-path dvv-ca.pem]
#                     [--vault-exe-source PATH] [--vault-exe-sha256 HEX] [--revocation-mode NoCheck]
#       Massaliittäminen. CSV: palvelin;ip;varmenne=host:port|host:port[;varmenne=...]
#       Luo roolit ja HAKEMISTO/<palvelin>.json (Install-WindowsAgent.ps1 -ParameterFile).
#       Tiedostoissa EI ole salaisuuksia: wrapping token luodaan vasta toimitushetkellä (wrap),
#       koska kääre vanhenee 15 minuutissa.
#
# Kääre on kertakäyttöinen ja vanhenee 15 min:ssa. Jos purku kohteessa epäonnistuu "already used"
# -virheeseen, joku on voinut siepata sen: älä ota käyttöön, aja remove ja selvitä.
set -euo pipefail
LOG_TAG=onboard
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }
WRAP_TTL=${WRAP_TTL:-15m}
SECRET_ID_TTL=${SECRET_ID_TTL:-2160h}   # 90 pv: kierrätys docs/windows-liittaminen.md

valid_name() { [[ "$1" =~ ^[a-z0-9-]+$ ]]; }
valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
}

TOK=""
admin() { [[ -n "$TOK" ]] || vault_admin_token TOK; }
v() { vault_tok "$TOK" "$@"; }   # Vault ylläpitäjän tokenilla (kutsuja ohjaa stdinin)

role_exists() { v read "auth/approle/role/$1" </dev/null >/dev/null 2>&1; }

create_role() { # create_role PALVELIN IP VARMENNE...
  local server=$1 ip=$2; shift 2
  local c policy=""
  valid_name "$server" || die "virheellinen palvelimen nimi: $server (a-z 0-9 -)"
  valid_ip "$ip" || die "virheellinen IPv4-osoite: $ip"
  (( $# > 0 )) || die "anna vähintään yksi varmenne"
  for c in "$@"; do
    valid_name "$c" || die "virheellinen varmenteen nimi: $c"
    v kv metadata get "secret/certs/$c" </dev/null >/dev/null 2>&1 ||
      log "VAROITUS: secret/certs/$c puuttuu Vaultista (lisää certs.conf:iin ja aja uusinta ennen agenttia)"
    policy+="path \"secret/data/certs/$c\" { capabilities = [\"read\"] }"$'\n'
  done
  printf '%s' "$policy" | v policy write "cert-$server" - >/dev/null
  v write "auth/approle/role/$server" \
    token_policies="cert-$server" token_ttl=1h token_max_ttl=24h \
    token_bound_cidrs="$ip/32" secret_id_bound_cidrs="$ip/32" \
    secret_id_ttl="$SECRET_ID_TTL" secret_id_num_uses=0 </dev/null >/dev/null
}

role_id() { v read -field=role_id "auth/approle/role/$1/role-id" </dev/null; }

wrapped_secret_id() {
  v write -wrap-ttl="$WRAP_TTL" -f -field=wrapping_token "auth/approle/role/$1/secret-id" </dev/null
}

accessors() { # vanhimmasta uusimpaan
  local a
  for a in $(v list -format=json "auth/approle/role/$1/secret-id" </dev/null 2>/dev/null | json_get '" ".join(d)' || true); do
    printf '%s %s\n' "$(printf '%s' "$a" | v write -format=json "auth/approle/role/$1/secret-id-accessor/lookup" secret_id_accessor=- |
      json_get 'd["data"]["creation_time"]')" "$a"
  done | sort | awk '{print $2}'
}

destroy_accessor() {
  printf '%s' "$2" | v write "auth/approle/role/$1/secret-id-accessor/destroy" secret_id_accessor=- >/dev/null
}

cmd_add() {
  admin; create_role "$@"
  local server=$1
  printf 'palvelin:           %s\n' "$server"
  printf 'role_id:            %s\n' "$(role_id "$server")"
  printf 'wrapped secret_id:  %s   (voimassa %s, kertakäyttöinen)\n' "$(wrapped_secret_id "$server")" "$WRAP_TTL"
}

cmd_wrap() {
  local server=${1:?anna palvelin}
  admin; role_exists "$server" || die "roolia $server ei ole (onboard-server.sh add)"
  printf 'wrapped secret_id:  %s   (voimassa %s, kertakäyttöinen)\n' "$(wrapped_secret_id "$server")" "$WRAP_TTL"
}

cmd_rotate() {
  local server=${1:?anna palvelin} old
  admin; role_exists "$server" || die "roolia $server ei ole"
  old=$(accessors "$server" | wc -l)
  cmd_wrap "$server"
  echo
  echo "Kierrätys: aja palvelimella Install-WindowsAgent.ps1 -WrappingToken <yllä> (tai Linux: vaihda secret_id),"
  echo "tarkista että agentti toimii, ja hävitä sitten $old vanha(a) secret_id:tä:"
  echo "  onboard-server.sh destroy-old $server"
}

cmd_destroy_old() {
  local server=${1:?anna palvelin} a n=0
  admin
  mapfile -t list < <(accessors "$server")
  (( ${#list[@]} > 1 )) || { log "$server: vain ${#list[@]} secret_id, ei hävitettävää"; return; }
  for a in "${list[@]:0:${#list[@]}-1}"; do destroy_accessor "$server" "$a"; n=$((n + 1)); done
  log "$server: $n vanhaa secret_id:tä hävitetty, uusin säilytetty"
}

cmd_remove() {
  local server=${1:?anna palvelin} a n=0
  valid_name "$server" || die "virheellinen palvelimen nimi"
  admin
  if role_exists "$server"; then
    for a in $(accessors "$server"); do destroy_accessor "$server" "$a"; n=$((n + 1)); done
    v delete "auth/approle/role/$server" </dev/null >/dev/null
  fi
  v policy delete "cert-$server" </dev/null >/dev/null 2>&1 || true
  log "$server poistettu: $n secret_id:tä hävitetty, rooli ja policy cert-$server poistettu"
}

cmd_list() {
  local r
  admin
  for r in $(v list -format=json auth/approle/role </dev/null 2>/dev/null | json_get '" ".join(d)' || true); do
    printf '%-24s %-18s %s\n' "$r" \
      "$(v read -format=json "auth/approle/role/$r" </dev/null | json_get '",".join(d["data"]["secret_id_bound_cidrs"] or [])')" \
      "$(v policy read "cert-$r" </dev/null 2>/dev/null | sed -n 's|.*secret/data/certs/\([a-z0-9-]*\).*|\1|p' | paste -sd,)"
  done
}

cmd_login() {
  local f=${1:?anna tiedosto} t
  [[ ! -e "$f" ]] || die "$f on jo olemassa"
  vault_login_admin t
  ( umask 077; printf '%s\n' "$t" > "$f" )
  log "Token tallennettu: $f (0600, voimassa enintään 1 h). Käyttö: VAULT_ADMIN_TOKEN_FILE=$f. Poista: shred -u $f"
}

cmd_csv() {
  local file=${1:?anna CSV-tiedosto}; shift
  local out="" ca="ca.pem" dvv="dvv-ca.pem" exe="vault.exe" sha="" rev="NoCheck" vaddr
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out=$2; shift 2 ;;
      --ca-path) ca=$2; shift 2 ;;
      --dvv-ca-path) dvv=$2; shift 2 ;;
      --vault-exe-source) exe=$2; shift 2 ;;
      --vault-exe-sha256) sha=$2; shift 2 ;;
      --revocation-mode) rev=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  [[ -n "$out" ]] || die "--out HAKEMISTO vaaditaan"
  [[ -r "$file" ]] || die "CSV ei ole luettavissa: $file"
  [[ "$rev" =~ ^(Online|Offline|NoCheck)$ ]] || die "--revocation-mode: Online|Offline|NoCheck"
  vaddr=$(env_get VAULT_API_ADDR); [[ -n "$vaddr" ]] || die "VAULT_API_ADDR puuttuu .env:stä"
  mkdir -p "$out"
  admin
  local line server ip rest field name binds n=0 certs=() json
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=';' read -r server ip rest <<< "$line"
    [[ -n "$rest" ]] || die "rivi '$line': varmenteet puuttuvat (palvelin;ip;varmenne=host:port|...)"
    certs=(); json=""
    IFS=';' read -ra fields <<< "$rest"
    for field in "${fields[@]}"; do
      name=${field%%=*}; binds=${field#*=}
      [[ "$field" == *=* && -n "$binds" ]] || die "rivi '$line': '$field' ei ole muotoa varmenne=host:port|host:port"
      valid_name "$name" || die "virheellinen varmenteen nimi: $name"
      [[ "$binds" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}(\|[A-Za-z0-9.-]+:[0-9]{1,5})*$ ]] || die "virheelliset sidokset: $binds"
      certs+=("$name")
      json+="${json:+,}\"$name\":[\"${binds//|/\",\"}\"]"
    done
    create_role "$server" "$ip" "${certs[@]}"
    python3 -c 'import sys,json
s, ip, vaddr, rid, ca, dvv, exe, sha, rev, certs = sys.argv[1:11]
print(json.dumps({"Server": s, "ServerIp": ip, "VaultAddress": vaddr, "RoleId": rid,
  "Certificates": json.loads("{" + certs + "}"), "CaPath": ca, "DvvCaPath": dvv,
  "VaultExeSource": exe, "VaultExeSha256": sha, "RevocationMode": rev}, indent=2))' \
      "$server" "$ip" "$vaddr" "$(role_id "$server")" "$ca" "$dvv" "$exe" "$sha" "$rev" "$json" > "$out/$server.json"
    n=$((n + 1))
  done < "$file"
  log "$n palvelinta: parametritiedostot hakemistossa $out (ei salaisuuksia)."
  log "Toimitushetkellä kullekin: onboard-server.sh wrap <palvelin>  (kääre vanhenee $WRAP_TTL)"
}

CMD=${1:-}; [[ $# -gt 0 ]] && shift
case "$CMD" in -h|--help|"") usage; [[ -n "$CMD" ]]; exit ;; esac
vault_running || die "$VAULT_CONTAINER ei ole käynnissä"
vault_is_sealed && die "Vault on sinetöity: vault-unseal.sh"
case "$CMD" in
  add) cmd_add "$@" ;;
  wrap) cmd_wrap "$@" ;;
  rotate) cmd_rotate "$@" ;;
  destroy-old) cmd_destroy_old "$@" ;;
  remove) cmd_remove "$@" ;;
  list) cmd_list ;;
  login) cmd_login "$@" ;;
  csv) cmd_csv "$@" ;;
  *) usage >&2; exit 2 ;;
esac
