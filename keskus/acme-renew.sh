#!/usr/bin/env bash
# /usr/local/sbin/acme-renew.sh  (root:root 0755) - ajetaan käyttäjänä "acme" systemd-timerillä.
# Käy läpi certs.conf:n: tilaa puuttuvat varmenteet (lego run) ja uusii
# vanhenemassa olevat (lego renew). Hook vie uudet varmenteet Vaultiin.
set -uo pipefail
set -a; source /etc/acme/lego.env; set +a
CONF=/etc/acme/certs.conf
HOOK=/usr/local/sbin/lego-hook.sh
FAIL=0

# Pidä keskuksen Vault-token (periodic) voimassa, vaikka varmenteita ei uusittaisi pitkään aikaan
( set -a; source /etc/acme/vault.env; vault token renew >/dev/null 2>&1 ) \
  || logger -t acme-renew -p warning "Vault-tokenin uusinta epäonnistui"

COMMON=(--accept-tos --key-type "$KEY_TYPE" --http --http.webroot /var/www/acme)
[[ -n "${LEGO_EAB_KID:-}" ]] && COMMON+=(--eab)      # kid/hmac luetaan ympäristömuuttujista, ei komentoriviltä

while read -r NAME DOMAINS; do
  [[ -z "$NAME" || "$NAME" == \#* ]] && continue
  [[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { logger -t acme-renew -p err "$NAME: virheellinen nimi"; FAIL=1; continue; }
  ARGS=("${COMMON[@]}" --filename "$NAME")
  IFS=',' read -ra DS <<< "$DOMAINS"
  for d in "${DS[@]}"; do ARGS+=(-d "$d"); done

  if [[ -e "$LEGO_PATH/certificates/$NAME.crt" ]]; then
    lego "${ARGS[@]}" renew --days "$RENEW_DAYS" --no-random-sleep --renew-hook "$HOOK" </dev/null || {
      logger -t acme-renew -p err "$NAME: uusinta epäonnistui"; FAIL=1; }
  else
    lego "${ARGS[@]}" run --run-hook "$HOOK" </dev/null || {
      logger -t acme-renew -p err "$NAME: tilaus epäonnistui"; FAIL=1; }
  fi
done < "$CONF"

exit $FAIL
