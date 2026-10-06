#!/usr/bin/env bash
# Konttiversio keskus/acme-renew.sh:sta (lego v5). Kontin entrypoint.
# Käy läpi certs.conf:n: lego v5:n "run" tilaa puuttuvat ja uusii erääntyvät varmenteet.
# Hook (lego-hook.sh) vie uudet varmenteet Vaultiin.
#
# Asetukset ympäristömuuttujina (compose / .env, EI salaisuuksia):
#   LEGO_SERVER, LEGO_EMAIL, KEY_TYPE, RENEW_DAYS (0 = legon dynaaminen), PFX_COMPAT,
#   VAULT_ADDR, VAULT_CACERT, HTTPS_PROXY/NO_PROXY (valinnaiset)
# Salaisuudet tiedostoina (podman secret):
#   /run/secrets/vault_token                 aina
#   /run/secrets/lego_eab_kid, lego_eab_hmac VAIN ensimmäisellä rekisteröinnillä (compose.eab.yaml)
#
# Ei "set -e": yhden varmenteen virhe ei saa keskeyttää muiden käsittelyä.
set -uo pipefail

CONF=${CERTS_CONF:-/etc/acme/certs.conf}
HOOK=/usr/local/bin/lego-hook.sh
WEBROOT=${ACME_WEBROOT:-/var/www/acme}
SECRETS=${SECRETS_DIR:-/run/secrets}
LEGO_PATH=${LEGO_PATH:-/var/lib/lego}
FAIL=0

log() { printf 'acme-renew: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Käyttö: acme-renew.sh [--help] [--dry-run]
  Tilaa ja uusii certs.conf:n varmenteet legolla ja vie ne Vaultiin (lego-hook.sh).
  --dry-run  tarkistaa asetukset ja tulostaa suunnitellut toimet, ei ota yhteyttä ACME:en eikä Vaultiin.
EOF
}

DRY_RUN=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

# Lukee salaisuuden tiedostosta; tyhjä tulos = puuttuu.
read_secret() {
  local f="$SECRETS/$1"
  [[ -r "$f" ]] || return 1
  tr -d '\r\n' < "$f"
}

for v in LEGO_SERVER LEGO_EMAIL VAULT_ADDR; do
  [[ -n "${!v:-}" ]] || { log "VIRHE: $v puuttuu. Aseta se .env-tiedostoon."; exit 2; }
done
[[ -r "$CONF" ]] || { log "VIRHE: $CONF ei ole luettavissa. Tarkista compose-liitos."; exit 2; }
KEY_TYPE=${KEY_TYPE:-RSA2048}
RENEW_DAYS=${RENEW_DAYS:-30}
[[ "$RENEW_DAYS" =~ ^[0-9]+$ ]] || { log "VIRHE: RENEW_DAYS ei ole luku"; exit 2; }

if (( ! DRY_RUN )); then
  VT=$(read_secret vault_token) && [[ -n "$VT" ]] \
    || { log "VIRHE: Vault-token puuttuu ($SECRETS/vault_token). Luo se: scripts/secrets.sh vault-token"; exit 1; }
  # Pidä keskuksen periodic-token voimassa, vaikka varmenteita ei uusittaisi pitkään aikaan.
  # Token annetaan vain tälle vault-prosessille, ei legolle.
  VAULT_TOKEN="$VT" vault token renew >/dev/null 2>&1 \
    || log "VAROITUS: Vault-tokenin uusinta epäonnistui. Onko Vault sinetöity? Tarkista: scripts/healthcheck.sh"
  unset VT
fi

COMMON=(--accept-tos --server "$LEGO_SERVER" --email "$LEGO_EMAIL" --key-type "$KEY_TYPE"
        --http --http.webroot "$WEBROOT" --no-random-sleep --deploy-hook "$HOOK")
(( RENEW_DAYS > 0 )) && COMMON+=(--renew-days "$RENEW_DAYS")

# EAB vain jos molemmat salaisuudet on annettu (ensimmäinen rekisteröinti).
# Arvot välitetään legolle ympäristömuuttujina, ei komentoriviltä.
if KID=$(read_secret lego_eab_kid) && HMAC=$(read_secret lego_eab_hmac) && [[ -n "$KID" && -n "$HMAC" ]]; then
  export LEGO_EAB=true LEGO_EAB_KID="$KID" LEGO_EAB_HMAC="$HMAC"
  log "EAB-tunnisteet annettu: ACME-tili rekisteröidään tarvittaessa."
fi
unset KID HMAC

# Lego v5 tallentaa tilin myös epäonnistuneesta rekisteröinnistä ("registration": null),
# eikä seuraava ajo (EAB:llä) enää yritä rekisteröintiä. Tällaista tiliä ei ole ACME-palvelimella,
# joten sen poistaminen on turvallista.
remove_unregistered_accounts() {
  local f
  while IFS= read -r -d '' f; do
    if grep -Eq '"registration": *null' "$f"; then
      log "VAROITUS: poistetaan rekisteröimätön ACME-tili $(dirname "$f") (edellinen rekisteröinti epäonnistui)"
      rm -rf -- "$(dirname "$f")"
    fi
  done < <(find "$LEGO_PATH/accounts" -name account.json -print0 2>/dev/null)
}
(( DRY_RUN )) || remove_unregistered_accounts

# Haastetiedostojen on oltava nginxin (eri uid) luettavissa: 0755/0644.
umask 022

while read -r NAME DOMAINS _; do
  [[ -z "${NAME:-}" || "$NAME" == \#* ]] && continue
  [[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { log "$NAME: virheellinen nimi (sallittu a-z 0-9 -)"; FAIL=1; continue; }
  [[ -n "${DOMAINS:-}" ]] || { log "$NAME: domainit puuttuvat"; FAIL=1; continue; }
  ARGS=("${COMMON[@]}" --cert.name "$NAME")
  IFS=',' read -ra DS <<< "$DOMAINS"
  for d in "${DS[@]}"; do
    [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || { log "$NAME: virheellinen domain '$d'"; FAIL=1; continue 2; }
    ARGS+=(-d "$d")
  done

  if (( DRY_RUN )); then
    printf 'lego run'; printf ' %q' "${ARGS[@]}"; printf '\n'
    continue
  fi
  if lego run "${ARGS[@]}" </dev/null; then
    log "$NAME: tarkistettu (tilattu/uusittu tarvittaessa)"
  else
    log "$NAME: tilaus tai uusinta epäonnistui. Katso legon virhe yltä."
    FAIL=1
  fi
done < "$CONF"

# Viimeisimmän onnistuneen ajon aikaleima valvontaa varten (smoke-test.sh)
if (( ! DRY_RUN && FAIL == 0 )); then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LEGO_PATH/last-success" 2>/dev/null || true
fi
exit "$FAIL"
