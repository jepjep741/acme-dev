#!/usr/bin/env bash
# Vaultin alustus ja perusasetukset (palvelukäyttäjänä, stack käynnissä). Idempotentti.
#
#   vault-init.sh init [--shares 5] [--threshold 3] [--pgp-keys a.asc,b.asc,...] [--root-pgp-key r.asc]
#                      [--out avainosat.json] [--no-configure]
#       Koko ensiasennus: operator init -> unseal -> configure -> ensimmäinen ylläpitäjä (+TOTP)
#       -> palvelutokenit podman secreteiksi -> ylläpitäjän kirjautumisen todennus -> root-token mitätöidään.
#       Ilman PGP:tä avainosat näytetään KERRAN päätteellä (vaatii TTY:n), eikä niitä kirjoiteta levylle.
#       PGP:llä salatut avainosat (ja root-token) tallennetaan --out-tiedostoon.
#   vault-init.sh configure             KV v2, AppRole, userpass, file-audit, policyt, token-roolit, TOTP-MFA
#   vault-init.sh admin-add NIMI [--reset-totp] [--totp-out TIEDOSTO]
#                                        ylläpitäjä (userpass + TOTP); otpauth-URL näytetään vain päätteellä
#   vault-init.sh login-test             todentaa ylläpitäjän kirjautumisen (salasana + TOTP)
#   vault-init.sh revoke-root            mitätöi root-tokenin (VAULT_ADMIN_TOKEN_FILE = root-token)
#
# Token configure/admin-add/revoke-root-komennoille: ylläpitäjän kirjautuminen (userpass+TOTP)
# tai VAULT_ADMIN_TOKEN_FILE (0600-tiedosto; vain alustuksessa ja testeissä).
set -euo pipefail
LOG_TAG=vault-init
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
POLICY_DIR=${POLICY_DIR:-$LIB_DIR/../vault/policies}
TOTP_ISSUER=${TOTP_ISSUER:-DVV-ACME}

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}; [[ $# -gt 0 ]] && shift
SHARES=5 THRESHOLD=3 PGP_KEYS="" ROOT_PGP="" OUT="" NO_CONFIGURE=0 RESET_TOTP=0 TOTP_OUT="" ADMIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shares) SHARES=$2; shift 2 ;;
    --threshold) THRESHOLD=$2; shift 2 ;;
    --pgp-keys) PGP_KEYS=$2; shift 2 ;;
    --root-pgp-key) ROOT_PGP=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --no-configure) NO_CONFIGURE=1; shift ;;
    --reset-totp) RESET_TOTP=1; shift ;;
    --totp-out) TOTP_OUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$ADMIN" ]] || { usage >&2; exit 2; }; ADMIN=$1; shift ;;
  esac
done

require_vault() { vault_running || die "$VAULT_CONTAINER ei ole käynnissä. Käynnistä: systemctl --user start acme-stack"; }
require_unsealed() { vault_is_sealed && die "Vault on sinetöity. Aja ensin: vault-unseal.sh"; return 0; }

# PGP-julkinen avain base64:nä (Vault vaatii binäärimuodon base64:nä)
pgp_b64() {
  local f=$1
  [[ -r "$f" ]] || die "PGP-avainta ei voi lukea: $f"
  if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$f"; then
    command -v gpg >/dev/null || die "gpg puuttuu (tarvitaan ASCII-armored-avaimille)"
    gpg --dearmor < "$f" | base64 -w0
  else
    base64 -w0 < "$f"
  fi
}

# ---------------------------------------------------------------------------
cmd_init() {
  require_vault
  if vault_is_initialized; then
    log "Vault on jo alustettu: operator init ohitetaan. Jatka: vault-unseal.sh, configure, admin-add."
    return 0
  fi
  if ! [[ "$SHARES" =~ ^[0-9]+$ && "$THRESHOLD" =~ ^[0-9]+$ ]] || (( THRESHOLD < 2 || THRESHOLD > SHARES )); then
    die "kynnys 2..osat (annettu --shares $SHARES --threshold $THRESHOLD)"
  fi

  local args=(-key-shares="$SHARES" -key-threshold="$THRESHOLD" -format=json) i=0 f files=() k
  if [[ -n "$PGP_KEYS" ]]; then
    [[ -n "$OUT" ]] || die "--out vaaditaan PGP-salattujen avainosien tallennukseen"
    IFS=',' read -ra files <<< "$PGP_KEYS"
    (( ${#files[@]} == SHARES )) || die "--pgp-keys: tarvitaan $SHARES avainta (annettu ${#files[@]})"
    for f in "${files[@]}"; do
      pgp_b64 "$f" | podman exec -i "$VAULT_CONTAINER" sh -c "cat > /tmp/pgp$i"
      k+="${k:+,}/tmp/pgp$i"; i=$((i + 1))
    done
    args+=(-pgp-keys="$k")
    if [[ -n "$ROOT_PGP" ]]; then
      pgp_b64 "$ROOT_PGP" | podman exec -i "$VAULT_CONTAINER" sh -c 'cat > /tmp/pgproot'
      args+=(-root-token-pgp-key=/tmp/pgproot)
    fi
  else
    [[ -t 0 && -t 2 ]] || die "ilman PGP-avaimia avainosat näytetään vain päätteellä: aja interaktiivisesti tai anna --pgp-keys"
    [[ -z "$ROOT_PGP" ]] || die "--root-pgp-key vaatii myös --pgp-keys"
  fi

  log "Alustetaan Vault: $SHARES avainosaa, kynnys $THRESHOLD${PGP_KEYS:+ (PGP-salattu)}"
  local resp root keys=()
  resp=$(vault_anon operator init "${args[@]}" </dev/null)
  podman exec "$VAULT_CONTAINER" sh -c 'rm -f /tmp/pgp*'
  mapfile -t keys < <(json_get '"\n".join(d["unseal_keys_b64"])' <<< "$resp")

  if [[ -n "$PGP_KEYS" ]]; then
    # Tallennetaan vain salatut avainosat (ja salattu root-token, jos --root-pgp-key).
    python3 -c 'import sys,json
d=json.loads(sys.stdin.read())
out={"unseal_keys_b64_pgp": d["unseal_keys_b64"], "unseal_shares": d["unseal_shares"],
     "unseal_threshold": d["unseal_threshold"], "pgp_fingerprints": d.get("pgp_fingerprints", [])}
if sys.argv[1] == "1": out["root_token_pgp"] = d["root_token"]
print(json.dumps(out, indent=2))' "$([[ -n "$ROOT_PGP" ]] && echo 1 || echo 0)" <<< "$resp" > "$OUT.new"
    chmod 0600 "$OUT.new"; mv -f "$OUT.new" "$OUT"
    log "PGP-salatut avainosat tallennettu: $OUT (toimita kukin osa haltijalleen; sormenjäljet tiedostossa)"
  else
    {
      printf '\n================= VAULTIN AVAINOSAT: NÄYTETÄÄN VAIN KERRAN =================\n'
      for i in "${!keys[@]}"; do printf 'Avainosa %d: %s\n' "$((i + 1))" "${keys[$i]}"; done
      printf '\nKirjaa kukin osa eri haltijalle (esim. sinetöity kirjekuori kassakaappiin).\n'
      printf 'Älä tallenna osia tälle palvelimelle, sähköpostiin tai yhteen paikkaan.\n'
      printf 'Avaamiseen tarvitaan %d osaa. Kirjoita KUITTAAN, kun osat on kirjattu: ' "$THRESHOLD"
    } > /dev/tty
    local ack=""; read -r ack < /dev/tty
    [[ "$ack" == KUITTAAN ]] || log "VAROITUS: kuittausta ei annettu. Avainosia ei voi näyttää uudelleen."
    printf '\033[2J\033[H' > /dev/tty    # tyhjennä näyttö
  fi

  if [[ -n "$ROOT_PGP" ]]; then
    root=""
  else
    root=$(json_get 'd["root_token"]' <<< "$resp")
  fi
  unset resp

  # Unseal: ilman PGP:tä avainosat ovat muistissa; PGP:llä haltijat avaavat itse.
  if [[ -z "$PGP_KEYS" ]]; then
    for ((i = 0; i < THRESHOLD; i++)); do
      printf '%s' "${keys[$i]}" | vault_anon write -format=json sys/unseal key=- >/dev/null
    done
    log "Vault avattu (unseal)."
  fi
  keys=()
  (( NO_CONFIGURE )) && { log "--no-configure: jatka vault-unseal.sh, configure, admin-add, tokens, revoke-root"; return 0; }

  if vault_is_sealed; then
    log "Pyydä avainosien haltijoita avaamaan Vault nyt (kynnys $THRESHOLD):"
    "$LIB_DIR/vault-unseal.sh"
  fi
  if [[ -z "$root" ]]; then
    log "Pura root-token PGP:llä (gpg --decrypt) ja syötä se:"
    read_secret root "Root-token"
  fi
  # Root-token vain muistissa: tämän prosessin ja sen aliprosessien ympäristössä (ei levylle,
  # ei komentoriville). Poistetaan heti mitätöinnin jälkeen.
  export _ACME_ADMIN_TOKEN="$root"; unset root
  trap 'unset _ACME_ADMIN_TOKEN' RETURN
  cmd_configure
  read_plain ADMIN "Ensimmäisen ylläpitäjän tunnus (esim. etunimi.sukunimi)"
  cmd_admin_add
  "$LIB_DIR/secrets.sh" vault-token
  "$LIB_DIR/secrets.sh" snapshot-token
  log "Todennetaan ylläpitäjän kirjautuminen (salasana + TOTP) ennen root-tokenin mitätöintiä:"
  until (unset _ACME_ADMIN_TOKEN; cmd_login_test); do
    log "Yritä uudelleen (Ctrl+C keskeyttää; root-token jää silloin voimaan: vault-init.sh revoke-root)."
  done
  cmd_revoke_root
  unset _ACME_ADMIN_TOKEN
}

# ---------------------------------------------------------------------------
cmd_configure() {
  require_vault; require_unsealed
  local tok acc mid p name
  vault_admin_token tok

  if ! vault_tok "$tok" secrets list -format=json </dev/null | json_get 'd["secret/"]["type"]' >/dev/null 2>&1; then
    vault_tok "$tok" secrets enable -path=secret -version=2 kv </dev/null >/dev/null; log "KV v2 otettu käyttöön: secret/"
  fi
  vault_tok "$tok" write secret/config max_versions=10 </dev/null >/dev/null
  for m in approle userpass; do
    if ! vault_tok "$tok" auth list -format=json </dev/null | json_get "d[\"$m/\"][\"type\"]" >/dev/null 2>&1; then
      vault_tok "$tok" auth enable "$m" </dev/null >/dev/null; log "Tunnistautuminen otettu käyttöön: $m"
    fi
  done
  if ! vault_tok "$tok" audit list -format=json </dev/null 2>/dev/null | json_get 'd["file/"]["type"]' >/dev/null 2>&1; then
    vault_tok "$tok" audit enable file file_path=/vault/logs/audit.log </dev/null >/dev/null
    log "File-audit otettu käyttöön: /vault/logs/audit.log"
  fi
  local names=()
  for p in "$POLICY_DIR"/*.hcl; do
    name=$(basename "$p" .hcl); names+=("$name")
    vault_tok "$tok" policy write "$name" - < "$p" >/dev/null
  done
  log "Policyt kirjoitettu: ${names[*]}"
  # Palvelutokenit token-roolien kautta: orpoja, periodic, vain oma policy.
  vault_tok "$tok" write auth/token/roles/acme-writer allowed_policies=acme-writer orphan=true \
    token_period=768h renewable=true token_type=service </dev/null >/dev/null
  vault_tok "$tok" write auth/token/roles/snapshot allowed_policies=snapshot orphan=true \
    token_period=768h renewable=true token_type=service </dev/null >/dev/null
  # TOTP-MFA ylläpitäjien userpass-kirjautumiselle
  acc=$(vault_tok "$tok" auth list -format=json </dev/null | json_get 'd["userpass/"]["accessor"]')
  mid=$(totp_method_id "$tok")
  if [[ -z "$mid" ]]; then
    mid=$(vault_tok "$tok" write -field=method_id identity/mfa/method/totp issuer="$TOTP_ISSUER" \
      period=30 key_size=20 algorithm=SHA1 digits=6 skew=1 </dev/null)
    log "TOTP-menetelmä luotu ($TOTP_ISSUER)"
  fi
  vault_tok "$tok" write identity/mfa/login-enforcement/admins mfa_method_ids="$mid" \
    auth_method_accessors="$acc" </dev/null >/dev/null
  log "Asetukset ajettu (idempotentti)."
}

totp_method_id() {
  vault_tok "$1" list -format=json identity/mfa/method/totp </dev/null 2>/dev/null |
    json_get 'd[0] if d else ""' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
cmd_admin_add() {
  require_vault; require_unsealed
  [[ "$ADMIN" =~ ^[a-z0-9._-]{2,64}$ ]] || die "anna ylläpitäjän tunnus (a-z 0-9 . _ -)"
  local tok pw pw2 acc eid mid url
  vault_admin_token tok
  read_secret pw "Uusi salasana käyttäjälle $ADMIN (väh. 14 merkkiä)"
  read_secret pw2 "Salasana uudelleen"
  [[ "$pw" == "$pw2" ]] || die "salasanat eivät täsmää"
  (( ${#pw} >= 14 )) || die "salasanan on oltava vähintään 14 merkkiä"
  printf '%s' "$pw" | vault_tok "$tok" write "auth/userpass/users/$ADMIN" password=- \
    token_policies=vault-admin,acme-admin,onboard-admin token_ttl=1h token_max_ttl=8h >/dev/null
  unset pw pw2
  acc=$(vault_tok "$tok" auth list -format=json </dev/null | json_get 'd["userpass/"]["accessor"]')
  eid=$(vault_tok "$tok" read -field=id "identity/entity/name/$ADMIN" </dev/null 2>/dev/null || true)
  if [[ -z "$eid" ]]; then
    eid=$(vault_tok "$tok" write -field=id identity/entity name="$ADMIN" </dev/null)
    vault_tok "$tok" write identity/entity-alias name="$ADMIN" canonical_id="$eid" mount_accessor="$acc" </dev/null >/dev/null
  fi
  mid=$(totp_method_id "$tok"); [[ -n "$mid" ]] || die "TOTP-menetelmä puuttuu: aja configure"
  if (( RESET_TOTP )); then
    vault_tok "$tok" write identity/mfa/method/totp/admin-destroy method_id="$mid" entity_id="$eid" </dev/null >/dev/null || true
  fi
  if url=$(vault_tok "$tok" write -field=url identity/mfa/method/totp/admin-generate method_id="$mid" entity_id="$eid" </dev/null 2>/dev/null) &&
     [[ -n "$url" ]]; then
    if [[ -n "$TOTP_OUT" ]]; then
      ( umask 077; printf '%s\n' "$url" > "$TOTP_OUT" ); log "TOTP-URL tallennettu: $TOTP_OUT (0600; poista käyttöönoton jälkeen)"
    else
      [[ -t 2 ]] || die "TOTP-URL näytetään vain päätteellä (tai --totp-out)"
      printf '\nLisää todennussovellukseen (näytetään kerran):\n%s\n\n' "$url" > /dev/tty
    fi
  else
    log "TOTP on jo määritetty käyttäjälle $ADMIN (uusi: --reset-totp)"
  fi
  log "Ylläpitäjä $ADMIN: policyt vault-admin, acme-admin, onboard-admin; token 1 h (max 8 h)"
}

cmd_login_test() {
  local tok
  vault_login_admin tok || return 1
  vault_tok "$tok" token lookup -format=json </dev/null | json_get '",".join(d["data"]["policies"])' |
    sed 's/^/vault-init: kirjautuminen OK, policyt: /' >&2
}

cmd_revoke_root() {
  local tok
  vault_admin_token tok
  vault_tok "$tok" token lookup -format=json </dev/null | json_get '"root" in d["data"]["policies"]' | grep -qx True ||
    die "annettu token ei ole root-token"
  vault_tok "$tok" token revoke -self </dev/null >/dev/null
  log "Root-token mitätöity. Uusi root-token vain avainosilla: vault operator generate-root (docs/runbook.md)."
}

case "$CMD" in
  init) cmd_init ;;
  configure) cmd_configure ;;
  admin-add) cmd_admin_add ;;
  login-test) require_vault; cmd_login_test ;;
  revoke-root) require_vault; cmd_revoke_root ;;
  -h|--help|"") usage; [[ -n "$CMD" ]] ;;
  *) usage >&2; exit 2 ;;
esac
