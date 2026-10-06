#!/usr/bin/env bash
# Keskuspalvelimen (RHEL 9) valmistelu rootless Podmania varten. Ajetaan rootina.
# Idempotentti: uudelleenajo tarkistaa ja korjaa, ei monista asetuksia.
#
# Tekee: paketit (podman, podman-compose [EPEL/sisäinen varasto], nftables, firewalld, openssl),
# palvelukäyttäjän (subuid/subgid, linger), hakemistot ja SELinux-kontekstit, firewalld-säännöt
# (8080 kaikkialta DNAT:n takia, Vault vain palvelinverkoista), palvelukäyttäjän egress-rajauksen
# (nftables, meta skuid) ja käyttäjän systemd-yksiköt. SELinux pysyy enforcing-tilassa.
set -euo pipefail

SVC_USER=acmesvc
SVC_HOME=/var/lib/acmesvc
RELEASE_LINK=/opt/acme/current
CONF_DIR=/etc/acme-podman
BACKUP_DIR=/srv/acme-backup
NFT_FILE=/etc/nftables/acme-egress.nft
ZONE=public
SERVER_CIDRS="" VAULT_IP="" EGRESS_ALLOW="" DNS_SERVERS=""
SKIP_PACKAGES=0 SKIP_FIREWALL=0 SKIP_EGRESS=0 SKIP_LINGER=0 LOCAL_DNAT=0 DRY_RUN=0
SVC_UID="" SUBUID_RANGE=""

usage() {
  cat <<'EOF'
Käyttö: install-host.sh <komento> [valinnat]

Komennot:
  install          valmistele isäntä (root)
  enable-services  ota käyttöön ja käynnistä käyttäjän yksiköt (vasta kun .env, TLS ja salaisuudet ovat valmiit)
  print-nft        tulosta egress-säännöt (ei muutoksia; testaus/tarkistus)
  check            tarkista isännän tila (ei muutoksia)

Valinnat (install):
  --server-cidrs CIDR[,CIDR]  palvelinverkot, joista Vault (TCP 8200) sallitaan  (pakollinen)
  --vault-ip IP               sisäverkon IP, johon Vault julkaistaan            (pakollinen)
  --egress-allow LISTA        palvelukäyttäjän sallitut kohteet IP[/maski]:portti[,...]
                              (DVV:n ACME- ja CRL-osoitteet tai välityspalvelin)
  --dns IP[,IP]               sisäiset DNS-palvelimet (palvelukäyttäjälle sallitaan UDP/TCP 53)
  --user NIMI                 palvelukäyttäjä (oletus acmesvc)
  --backup-dir HAKEMISTO      varmuuskopioiden kohde (oletus /srv/acme-backup)
  --zone ZONE                 firewalld-vyöhyke (oletus public)
  --local-dnat                tee 80 -> 8080 -ohjaus tällä isännällä (oletus: perimetripalomuuri tekee)
  --skip-packages             älä asenna paketteja, vain tarkista (ilmarako ilman varastoa)
  --skip-firewall | --skip-egress | --skip-linger
  --dry-run                   näytä toimet tekemättä niitä
  --help
Valinnat (print-nft): --egress-allow, --dns, --user TAI --uid N [--subuid-range ALKU-LOPPU]
EOF
}

log() { printf 'install-host: %s\n' "$*" >&2; }
die() { log "VIRHE: $*"; exit 1; }
run() {
  if (( DRY_RUN )); then printf 'install-host: [dry-run]'; printf ' %q' "$@"; printf '\n'; return 0; fi
  "$@"
}

CMD=${1:-}; [[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-cidrs) SERVER_CIDRS=$2; shift 2 ;;
    --vault-ip) VAULT_IP=$2; shift 2 ;;
    --egress-allow) EGRESS_ALLOW=$2; shift 2 ;;
    --dns) DNS_SERVERS=$2; shift 2 ;;
    --user) SVC_USER=$2; shift 2 ;;
    --uid) SVC_UID=$2; shift 2 ;;
    --subuid-range) SUBUID_RANGE=$2; shift 2 ;;
    --backup-dir) BACKUP_DIR=$2; shift 2 ;;
    --zone) ZONE=$2; shift 2 ;;
    --local-dnat) LOCAL_DNAT=1; shift ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    --skip-egress) SKIP_EGRESS=1; shift ;;
    --skip-linger) SKIP_LINGER=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$CMD" == "-h" || "$CMD" == "--help" ]] && { usage; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PODMAN_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Syötteiden tarkistus ------------------------------------------------------
IPV4_RE='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
valid_ipv4() {
  [[ "$1" =~ $IPV4_RE ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do (( o <= 255 )) || return 1; done
}
valid_cidr() {
  local ip=${1%/*} m=32
  [[ "$1" == */* ]] && m=${1#*/}
  valid_ipv4 "$ip" && [[ "$m" =~ ^[0-9]+$ ]] && (( m <= 32 ))
}
split_csv() { local IFS=','; read -ra _OUT <<< "$1"; }

validate_lists() {
  local x
  split_csv "$EGRESS_ALLOW"
  for x in "${_OUT[@]}"; do
    [[ "$x" == *:* ]] || die "--egress-allow: '$x' ei ole muotoa IP[/maski]:portti"
    valid_cidr "${x%:*}" || die "--egress-allow: virheellinen osoite '${x%:*}'"
    local port=${x##*:}
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      die "--egress-allow: virheellinen portti '$port'"
    fi
  done
  split_csv "$DNS_SERVERS"
  for x in "${_OUT[@]}"; do valid_ipv4 "$x" || die "--dns: virheellinen IPv4 '$x'"; done
  split_csv "$SERVER_CIDRS"
  for x in "${_OUT[@]}"; do valid_cidr "$x" || die "--server-cidrs: virheellinen CIDR '$x'"; done
  [[ -z "$VAULT_IP" ]] || valid_ipv4 "$VAULT_IP" || die "--vault-ip: virheellinen IPv4 '$VAULT_IP'"
  [[ "$SVC_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "--user: virheellinen käyttäjänimi"
}

# --- nftables: palvelukäyttäjän egress ------------------------------------------
# Rootless-tilassa konttien ulosmenevä liikenne lähtee isännältä joko palvelukäyttäjän omista
# prosesseista (pasta, aardvark-dns: bridge-verkot) TAI isännän verkossa ajettavien konttien
# prosesseista, joiden uid isännällä on palvelukäyttäjän subuid-alueella (esim. Vault uid 100 ->
# 100099). Siksi rajaus kattaa sekä uid:n että koko subuid-alueen. Kontin tason eristys
# (internal-verkot) on toinen kerros.

# Palvelukäyttäjän subuid-alue muodossa ALKU-LOPPU (/etc/subuid: nimi:alku:määrä)
subuid_range() {
  local start count
  IFS=: read -r _ start count < <(grep -m1 "^$1:" /etc/subuid) || return 1
  [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || return 1
  echo "$start-$((start + count - 1))"
}

render_nft() {
  local uid=$1 range=$2 x allow=() dns=()
  split_csv "$EGRESS_ALLOW"; for x in "${_OUT[@]}"; do allow+=("${x%:*} . ${x##*:}"); done
  split_csv "$DNS_SERVERS"; for x in "${_OUT[@]}"; do dns+=("$x"); done
  cat <<EOF
# Luotu: install-host.sh. ÄLÄ muokkaa käsin, aja install-host.sh uudelleen.
# Palvelukäyttäjän ($SVC_USER, uid $uid, subuid $range) sallitut ulosmenevät yhteydet; muu hylätään.
table inet acme_egress
delete table inet acme_egress
table inet acme_egress {
	set allow4 {
		type ipv4_addr . inet_service
		flags interval
EOF
  local joined
  if (( ${#allow[@]} )); then joined=$(IFS=,; echo "${allow[*]}"); printf '\t\telements = { %s }\n' "${joined//,/, }"; fi
  cat <<EOF
	}
	set dns4 {
		type ipv4_addr
EOF
  if (( ${#dns[@]} )); then joined=$(IFS=,; echo "${dns[*]}"); printf '\t\telements = { %s }\n' "${joined//,/, }"; fi
  cat <<EOF
	}
	# Vain palvelukäyttäjän socketeista lähtevät paketit rajataan; muu liikenne (myös ytimen
	# itse tuottamat paketit ilman socketia) ohittaa ketjun.
	chain output {
		type filter hook output priority filter; policy accept;
		meta skuid { $uid, $range } jump svc_out
	}
	chain svc_out {
		oifname "lo" accept
		ct state established,related accept
		ip daddr @dns4 udp dport 53 accept
		ip daddr @dns4 tcp dport 53 accept
		ip daddr . tcp dport @allow4 accept
		limit rate 6/minute log prefix "acme-egress-drop: " level warn
		counter reject
	}
}
EOF
}

# --- Paketit ---------------------------------------------------------------
PACKAGES=(podman podman-compose nftables firewalld openssl policycoreutils-python-utils)
ensure_packages() {
  local missing=() p
  for p in "${PACKAGES[@]}"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  (( ${#missing[@]} )) || { log "Paketit asennettu: ${PACKAGES[*]}"; return; }
  if (( SKIP_PACKAGES )); then
    die "puuttuvat paketit: ${missing[*]}. Asenna sisäisestä varastosta tai julkaisupaketin RPM:istä."
  fi
  log "Asennetaan: ${missing[*]} (podman-compose: EPEL tai sisäinen varasto)"
  run dnf -y install "${missing[@]}"
}

# --- Palvelukäyttäjä ----------------------------------------------------------
next_subid_start() { # seuraava vapaa 65536-alue tiedostossa
  awk -F: 'BEGIN{m=100000} {e=$2+$3; if (e>m) m=e} END{print m}' "$1" 2>/dev/null || echo 100000
}

ensure_user() {
  if id "$SVC_USER" >/dev/null 2>&1; then
    log "Käyttäjä $SVC_USER on olemassa"
  else
    log "Luodaan palvelukäyttäjä $SVC_USER (koti $SVC_HOME, ei kirjautumista)"
    run useradd --system --create-home --home-dir "$SVC_HOME" --shell /usr/sbin/nologin \
      --comment "DVV ACME rootless podman" "$SVC_USER"
  fi
  local f start
  for f in /etc/subuid /etc/subgid; do
    if grep -q "^$SVC_USER:" "$f" 2>/dev/null; then
      log "$f: $SVC_USER on jo määritelty"
    else
      start=$(next_subid_start "$f")
      log "$f: lisätään $SVC_USER:$start:65536"
      if [[ "$f" == /etc/subuid ]]; then run usermod --add-subuids "$start-$((start + 65535))" "$SVC_USER"
      else run usermod --add-subgids "$start-$((start + 65535))" "$SVC_USER"; fi
    fi
  done
  run chmod 0700 "$SVC_HOME"
  if (( ! SKIP_LINGER )); then
    run loginctl enable-linger "$SVC_USER"
  fi
}

# --- Hakemistot ja SELinux ----------------------------------------------------
ensure_dirs() {
  run install -d -m 0755 -o root -g root /opt/acme /opt/acme/releases
  run install -d -m 0755 -o root -g "$SVC_USER" "$CONF_DIR"
  run install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$CONF_DIR/tls"
  run install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$BACKUP_DIR"
  if [[ ! -e "$CONF_DIR/.env" && -r "$PODMAN_SRC/.env.example" ]]; then
    log "Kopioidaan pohja $CONF_DIR/.env (täytä <...>-arvot)"
    run install -m 0640 -o root -g "$SVC_USER" "$PODMAN_SRC/.env.example" "$CONF_DIR/.env"
  fi
  if [[ ! -e "$CONF_DIR/certs.conf" && -r "$PODMAN_SRC/config/certs.conf" ]]; then
    run install -m 0644 -o root -g root "$PODMAN_SRC/config/certs.conf" "$CONF_DIR/certs.conf"
  fi
  if command -v selinuxenabled >/dev/null && selinuxenabled; then
    [[ "$(getenforce)" == Enforcing ]] || log "VAROITUS: SELinux ei ole Enforcing-tilassa ($(getenforce)). Tätä skripti ei muuta."
    # Konteille vain luku -tilassa liitettävät konfiguraatiot (ei :z-uudelleenmerkintää root-tiedostoille)
    local p
    for p in "/opt/acme(/.*)?" "$CONF_DIR(/.*)?"; do
      if ! semanage fcontext -l | grep -qF "$p "; then
        run semanage fcontext -a -t container_ro_file_t "$p"
      fi
    done
    run restorecon -R /opt/acme "$CONF_DIR"
  else
    log "SELinux ei ole käytössä tällä isännällä: kontekstit ohitetaan (tuotannossa RHEL: Enforcing)"
  fi
}

# --- firewalld ----------------------------------------------------------------
ensure_firewall() {
  systemctl is-active --quiet firewalld || run systemctl enable --now firewalld
  run firewall-cmd --permanent --zone="$ZONE" --add-port=8080/tcp
  local c
  split_csv "$SERVER_CIDRS"
  for c in "${_OUT[@]}"; do
    run firewall-cmd --permanent --zone="$ZONE" \
      --add-rich-rule="rule family=ipv4 source address=$c destination address=$VAULT_IP port port=8200 protocol=tcp accept"
  done
  if (( LOCAL_DNAT )); then
    run firewall-cmd --permanent --zone="$ZONE" --add-forward-port=port=80:proto=tcp:toport=8080
  fi
  run firewall-cmd --reload
  log "firewalld: 8080/tcp sallittu (DNAT 80 -> 8080), 8200/tcp vain: $SERVER_CIDRS -> $VAULT_IP"
}

# --- egress ---------------------------------------------------------------------
ensure_egress() {
  local uid
  if ! uid=$(id -u "$SVC_USER" 2>/dev/null); then
    (( DRY_RUN )) || die "käyttäjää $SVC_USER ei ole"
    uid='<uid>'   # dry-run: käyttäjä luotaisiin edellä
  fi
  [[ -n "$EGRESS_ALLOW" ]] || log "VAROITUS: --egress-allow on tyhjä: palvelukäyttäjä ei pääse DVV:hen ennen kuin osoitteet lisätään."
  [[ -n "$DNS_SERVERS" ]] || log "VAROITUS: --dns on tyhjä: palvelukäyttäjän nimikyselyt estetään."
  run install -d -m 0755 /etc/nftables
  local range
  if ! range=$(subuid_range "$SVC_USER"); then
    (( DRY_RUN )) || die "$SVC_USER:n subuid-alue puuttuu /etc/subuid:sta"
    range='<subuid-alku>-<loppu>'
  fi
  if (( DRY_RUN )); then render_nft "$uid" "$range" >&2; else
    render_nft "$uid" "$range" > "$NFT_FILE.new"
    nft -c -f "$NFT_FILE.new" || die "nftables-säännöt eivät kelpaa ($NFT_FILE.new)"
    chmod 0600 "$NFT_FILE.new"; mv -f "$NFT_FILE.new" "$NFT_FILE"
  fi
  run install -m 0644 "$PODMAN_SRC/systemd/acme-egress-nft.service" /etc/systemd/system/acme-egress-nft.service
  run systemctl daemon-reload
  run systemctl enable acme-egress-nft.service
  run systemctl restart acme-egress-nft.service
  log "Egress-rajaus ladattu: $NFT_FILE"
}

# --- Käyttäjän systemd-yksiköt ------------------------------------------------
user_units() {
  local f
  for f in "$PODMAN_SRC"/systemd/*.service "$PODMAN_SRC"/systemd/*.timer; do
    f=${f##*/}; [[ "$f" == acme-egress-nft.service ]] || echo "$f"
  done
}

ensure_user_units() {
  local d="$SVC_HOME/.config/systemd/user" u
  run install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$SVC_HOME/.config" "$SVC_HOME/.config/systemd" "$d"
  for u in $(user_units); do
    run install -m 0644 -o "$SVC_USER" -g "$SVC_USER" "$PODMAN_SRC/systemd/$u" "$d/$u"
  done
  if (( ! SKIP_LINGER )); then run systemctl --user -M "$SVC_USER@" daemon-reload; fi
  log "Käyttäjän yksiköt asennettu: $d (ota käyttöön: install-host.sh enable-services)"
}

enable_services() {
  local env="$CONF_DIR/.env"
  [[ -r "$env" ]] || die "$env puuttuu"
  grep -Eq '^[^#]*=.*<[^>]+>' "$env" && die "$env sisältää täyttämättömiä <...>-arvoja"
  run systemctl --user -M "$SVC_USER@" enable --now acme-stack.service
  run systemctl --user -M "$SVC_USER@" enable --now acme-renew.timer vault-snapshot.timer vault-audit-rotate.timer
  log "Käytössä. Vault on sinetöity, kunnes ajat: scripts/vault-unseal.sh"
}

# --- Tarkistus ------------------------------------------------------------------
CHECK_RC=0
# chk "kuvaus" "korjausohje" komento...   (tulostaa [OK] tai [VIKA])
chk() {
  local desc=$1 fix=$2; shift 2
  if "$@" >/dev/null 2>&1; then printf '  [OK]   %s\n' "$desc"
  else printf '  [VIKA] %s -> %s\n' "$desc" "$fix"; CHECK_RC=1; fi
}
not() { ! "$@"; }

check() {
  local p
  echo "Isännän tarkistus:"
  for p in "${PACKAGES[@]}"; do chk "paketti $p" "asenna paketti" rpm -q "$p"; done
  chk "käyttäjä $SVC_USER" "install-host.sh install" id "$SVC_USER"
  chk "subuid" "install-host.sh install" grep -q "^$SVC_USER:" /etc/subuid
  chk "subgid" "install-host.sh install" grep -q "^$SVC_USER:" /etc/subgid
  chk "linger" "loginctl enable-linger $SVC_USER" test -e "/var/lib/systemd/linger/$SVC_USER"
  if command -v getenforce >/dev/null; then
    chk "SELinux Enforcing" "palauta Enforcing-tila (setenforce 1, /etc/selinux/config)" test "$(getenforce)" = Enforcing
  fi
  chk "firewalld käynnissä" "systemctl enable --now firewalld" systemctl is-active --quiet firewalld
  chk "firewalld 8080/tcp" "install-host.sh install" firewall-cmd --zone="$ZONE" --query-port=8080/tcp
  chk "8200/tcp ei auki kaikille" "poista: firewall-cmd --permanent --remove-port=8200/tcp" \
    not firewall-cmd --zone="$ZONE" --query-port=8200/tcp
  chk "nftables acme_egress ladattu" "systemctl restart acme-egress-nft" nft list table inet acme_egress
  chk "$CONF_DIR/.env" "kopioi .env.example ja täytä" test -r "$CONF_DIR/.env"
  chk "$RELEASE_LINK" "import-release.sh" test -L "$RELEASE_LINK"
  return "$CHECK_RC"
}

require_root() { [[ $EUID -eq 0 ]] || (( DRY_RUN )) || die "aja rootina (sudo)"; }

case "$CMD" in
  install)
    require_root
    validate_lists
    [[ -n "$SERVER_CIDRS" && -n "$VAULT_IP" ]] || die "--server-cidrs ja --vault-ip ovat pakollisia"
    ensure_packages
    ensure_user
    ensure_dirs
    (( SKIP_FIREWALL )) || ensure_firewall
    (( SKIP_EGRESS )) || ensure_egress
    ensure_user_units
    log "Valmis. Seuraavaksi: täytä $CONF_DIR/.env, tls-init.sh, secrets.sh, enable-services (docs/keskuspalvelin-podman.md)"
    (( DRY_RUN )) || check || true
    ;;
  enable-services) require_root; enable_services ;;
  print-nft)
    validate_lists
    if [[ -z "$SVC_UID" ]]; then SVC_UID=$(id -u "$SVC_USER" 2>/dev/null) || die "käyttäjää $SVC_USER ei ole; anna --uid"; fi
    [[ "$SVC_UID" =~ ^[0-9]+$ ]] || die "--uid: virheellinen"
    if [[ -z "$SUBUID_RANGE" ]]; then SUBUID_RANGE=$(subuid_range "$SVC_USER") || die "subuid-alue puuttuu; anna --subuid-range"; fi
    if ! [[ "$SUBUID_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]] || (( BASH_REMATCH[1] > BASH_REMATCH[2] )); then
      die "--subuid-range: virheellinen"
    fi
    render_nft "$SVC_UID" "$SUBUID_RANGE" ;;
  check) check ;;
  *) usage >&2; exit 2 ;;
esac
