#!/usr/bin/env bash
# Vaultin TLS-varmenne: luo sisäisen CA:n ja palvelinvarmenteen TAI tuo olemassa olevat.
# Palvelimen yksityinen avain viedään suoraan podman secretiksi (vault_tls_key), ei levylle.
# Ajetaan palvelukäyttäjänä (acmesvc). Idempotentti: olemassa olevaa CA:ta ei luoda uudelleen,
# ja voimassa oleva palvelinvarmenne, jonka SAN täsmää, jätetään ennalleen.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Käyttö:
  tls-init.sh generate --dir DIR --dns vault.asiakas.fi --ip 10.0.0.10 [--days 397] [--ca-days 3650] [--renew]
  tls-init.sh import   --dir DIR --cert server.pem --key server.key --ca ca.pem
  Yhteiset: [--secret-name vault_tls_key] [--dry-run] [--help]

generate: luo DIR/private/ca.key (vain jos puuttuu), DIR/ca.pem ja DIR/vault.crt.
          SAN: --dns, --ip, vault, 127.0.0.1 (kontin sisäinen käyttö).
          --renew luo palvelinvarmenteen uudelleen, vaikka nykyinen olisi kelvollinen.
import:   tuo asiakkaan PKI:n varmenteen (ketjuineen) ja avaimen. Avain viedään podman secretiksi;
          lähdetiedostoa ei poisteta (tee se itse turvallisesti).

Tulostaa lopuksi polun DIR/ca.pem, joka jaetaan agenteille ja lego-kontille.
CA:n avain (DIR/private/ca.key) siirretään käyttöönoton jälkeen offline-säilöön.
EOF
}

log() { printf 'tls-init: %s\n' "$*" >&2; }
die() { log "VIRHE: $*"; exit 1; }
run() { if (( DRY_RUN )); then log "[dry-run] $*"; else "$@"; fi; }

MODE=${1:-}; [[ $# -gt 0 ]] && shift
DIR="" DNS="" IP="" DAYS=397 CA_DAYS=3650 RENEW=0 DRY_RUN=0
CERT="" KEY="" CA="" SECRET=vault_tls_key
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR=$2; shift 2 ;;
    --dns) DNS=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --days) DAYS=$2; shift 2 ;;
    --ca-days) CA_DAYS=$2; shift 2 ;;
    --renew) RENEW=1; shift ;;
    --cert) CERT=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --ca) CA=$2; shift 2 ;;
    --secret-name) SECRET=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$MODE" == "-h" || "$MODE" == "--help" ]] && { usage; exit 0; }
[[ -n "$DIR" ]] || { usage >&2; exit 2; }

# Tallentaa avaimen podman secretiksi stdinin kautta (ei komentoriville).
store_key_secret() {
  local keyfile=$1
  if (( DRY_RUN )); then log "[dry-run] podman secret create --replace $SECRET <avain>"; return; fi
  podman secret create --replace "$SECRET" - < "$keyfile" >/dev/null
  log "Avain tallennettu podman secretiksi: $SECRET"
}

# Onko varmenne voimassa >30 pv ja sisältääkö se annetut SAN-nimet?
cert_ok() {
  local crt=$1 san
  [[ -s "$crt" ]] || return 1
  openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null || return 1
  san=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2)
  [[ "$san" == *"DNS:$DNS"* && "$san" == *"IP Address:$IP"* && "$san" == *"DNS:vault"* ]]
}

generate() {
  [[ -n "$DNS" && -n "$IP" ]] || die "--dns ja --ip vaaditaan"
  [[ "$DNS" =~ ^[A-Za-z0-9.-]+$ ]] || die "virheellinen DNS-nimi: $DNS"
  [[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "virheellinen IPv4-osoite: $IP"
  run install -d -m 0755 "$DIR"
  run install -d -m 0700 "$DIR/private"

  if [[ -s "$DIR/ca.pem" && -s "$DIR/private/ca.key" ]]; then
    log "Sisäinen CA on jo olemassa: $DIR/ca.pem (ei luoda uudelleen)"
  elif [[ -s "$DIR/ca.pem" ]]; then
    die "$DIR/ca.pem on olemassa mutta CA:n avain puuttuu. Palauta avain offline-säilöstä tai poista ca.pem tietoisesti."
  else
    log "Luodaan sisäinen CA ($CA_DAYS pv)"
    run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -nodes \
      -keyout "$DIR/private/ca.key" -out "$DIR/ca.pem" -days "$CA_DAYS" -sha384 \
      -subj "/CN=DVV ACME Vault internal CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    (( DRY_RUN )) || chmod 0644 "$DIR/ca.pem"
  fi

  if (( ! RENEW )) && cert_ok "$DIR/vault.crt"; then
    log "Palvelinvarmenne on kelvollinen ja SAN täsmää: $DIR/vault.crt (ohitetaan; --renew pakottaa)"
    if ! podman secret exists "$SECRET" 2>/dev/null; then
      die "podman secret $SECRET puuttuu, vaikka varmenne on olemassa. Luo varmenne uudelleen: --renew"
    fi
    return
  fi

  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  log "Luodaan palvelinvarmenne ($DAYS pv): DNS:$DNS, IP:$IP, DNS:vault, IP:127.0.0.1"
  run openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$tmp/vault.key" -out "$tmp/vault.csr" -subj "/CN=$DNS" 2>/dev/null
  printf '%s\n' "subjectAltName=DNS:$DNS,IP:$IP,DNS:vault,IP:127.0.0.1" \
    "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" > "$tmp/ext.cnf"
  run openssl x509 -req -in "$tmp/vault.csr" -CA "$DIR/ca.pem" -CAkey "$DIR/private/ca.key" \
    -CAcreateserial -CAserial "$DIR/private/ca.srl" -days "$DAYS" -sha256 \
    -extfile "$tmp/ext.cnf" -out "$tmp/vault.crt" 2>/dev/null
  store_key_secret "$tmp/vault.key"
  run install -m 0644 "$tmp/vault.crt" "$DIR/vault.crt"
}

import() {
  [[ -r "$CERT" && -r "$KEY" && -r "$CA" ]] || die "--cert, --key ja --ca vaaditaan ja niiden on oltava luettavissa"
  # Avain vastaa varmennetta
  diff -q <(openssl x509 -in "$CERT" -noout -pubkey) <(openssl pkey -in "$KEY" -pubout 2>/dev/null) >/dev/null \
    || die "avain ei vastaa varmennetta"
  openssl verify -CAfile "$CA" -untrusted "$CERT" "$CERT" >/dev/null 2>&1 \
    || die "varmenne ei validoidu annettuun CA:han"
  openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -q 'DNS:vault' \
    || log "VAROITUS: SAN ei sisällä nimeä 'vault'. Lego-kontti käyttää osoitetta https://vault:8200; lisää SAN tai muuta VAULT_ADDR."
  run install -d -m 0755 "$DIR"
  run install -m 0644 "$CA" "$DIR/ca.pem"
  run install -m 0644 "$CERT" "$DIR/vault.crt"
  store_key_secret "$KEY"
}

command -v openssl >/dev/null || die "openssl puuttuu"
command -v podman >/dev/null || die "podman puuttuu"
case "$MODE" in
  generate) generate ;;
  import) import ;;
  *) usage >&2; exit 2 ;;
esac
log "Valmis. Jaa agenteille ja lego-kontille: $DIR/ca.pem"
printf '%s\n' "$DIR/ca.pem"
