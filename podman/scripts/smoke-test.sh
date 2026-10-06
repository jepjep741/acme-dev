#!/usr/bin/env bash
# Savutesti asennuksen ja päivityksen jälkeen (palvelukäyttäjänä). Toimii täysin offline.
#   1. kontit acme-nginx ja acme-vault käynnissä
#   2. Vault alustettu ja avattu
#   3. nginx tarjoilee haastepolun (testitiedosto webrootiin, haku julkaistusta portista)
#   4. viimeisin onnistunut uusinta (lego-data/last-success)
#   5. varmenteiden not_after Vaultissa (custom_metadata, acme-writer-token: ei pääsyä avaimiin)
# Paluukoodi 0 = kaikki OK, 1 = vikoja. Ei tulosta salaisuuksia.
set -euo pipefail
LOG_TAG=smoke-test
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

RENEW_MAX_HOURS=${RENEW_MAX_HOURS:-36}
CERT_MIN_DAYS=${CERT_MIN_DAYS:-14}
case "${1:-}" in
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; echo "Ympäristö: RENEW_MAX_HOURS=36 CERT_MIN_DAYS=14"; exit 0 ;;
  "") ;;
  *) echo "Käyttö: $0 [--help]" >&2; exit 2 ;;
esac

RC=0
ok() { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [VIKA] %s\n' "$*"; RC=1; }
now=$(date +%s)
img=$(env_get LEGO_IMAGE)

echo "1. Kontit"
for c in acme-nginx acme-vault; do
  if podman container exists "$c" && [[ "$(podman inspect -f '{{.State.Running}}' "$c")" == true ]]; then ok "$c käynnissä"
  else bad "$c ei käynnissä (acme-compose.sh up -d)"; fi
done

echo "2. Vault"
if js=$(vault_status_json 2>/dev/null); then
  if [[ "$(json_get 'd["initialized"]' <<< "$js")" != True ]]; then bad "Vault alustamaton (vault-init.sh init)"
  elif [[ "$(json_get 'd["sealed"]' <<< "$js")" == True ]]; then bad "Vault sinetöity (vault-unseal.sh)"
  else ok "Vault avattu ($(json_get 'd["version"]' <<< "$js"))"; fi
else bad "Vault ei vastaa"; fi

echo "3. nginx: haastepolku"
pub=$(env_get NGINX_PUBLISH); pub=${pub:-8080}; port=${pub##*:}
host=127.0.0.1; [[ "$pub" == *:* ]] && host=${pub%:*}
tok="smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
if [[ -n "$img" ]] && podman run --rm --log-driver none --network none -v acme_acme-webroot:/w:z --entrypoint sh "$img" \
     -c "umask 022; mkdir -p /w/.well-known/acme-challenge && printf '%s' '$tok' > /w/.well-known/acme-challenge/$tok" 2>/dev/null; then
  got=$(curl -s --max-time 5 "http://$host:$port/.well-known/acme-challenge/$tok" || true)
  if [[ "$got" == "$tok" ]]; then ok "haastepolku vastaa (http://$host:$port/.well-known/acme-challenge/)"
  else bad "haastepolku ei palauttanut testitiedostoa (portti $port, webroot-oikeudet?)"; fi
  podman run --rm --log-driver none --network none -v acme_acme-webroot:/w:z --entrypoint rm "$img" \
    -f "/w/.well-known/acme-challenge/$tok" 2>/dev/null || true
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: smoke.invalid' "http://$host:$port/x" || true)
  if [[ "$code" == 301 ]]; then ok "muu liikenne -> 301 https"; else bad "muu liikenne palautti $code (odotettu 301)"; fi
else bad "testitiedostoa ei voitu kirjoittaa webrootiin (LEGO_IMAGE, volyymi acme_acme-webroot)"; fi

echo "4. Uusinta"
last=$(podman run --rm --log-driver none --network none -v acme_lego-data:/d:ro --entrypoint cat "$img" /d/last-success 2>/dev/null || true)
if [[ -z "$last" ]]; then bad "ei onnistunutta uusintaa (journalctl --user -t acme-renew)"
else
  age=$(( (now - $(date -d "$last" +%s)) / 3600 ))
  if (( age <= RENEW_MAX_HOURS )); then ok "viimeisin onnistunut uusinta $last ($age h sitten)"
  else bad "viimeisin onnistunut uusinta $last ($age h sitten > $RENEW_MAX_HOURS h)"; fi
fi

echo "5. Varmenteet Vaultissa (not_after)"
if podman secret exists vault_token && vault_running && ! vault_is_sealed; then
  t=$(get_secret vault_token)
  names=$(vault_tok "$t" kv list -format=json secret/certs </dev/null 2>/dev/null | json_get '" ".join(d)' || true)
  [[ -n "$names" ]] || bad "Vaultissa ei ole varmenteita (secret/certs)"
  for n in $names; do
    na=$(vault_tok "$t" kv metadata get -format=json "secret/certs/$n" </dev/null 2>/dev/null |
      json_get '(d["data"].get("custom_metadata") or {}).get("not_after","")' || true)
    if [[ -z "$na" ]]; then bad "$n: not_after puuttuu metadatasta (uusi varmenne seuraavalla uusinnalla)"; continue; fi
    days=$(( ($(date -d "$na" +%s) - now) / 86400 ))
    if (( days >= CERT_MIN_DAYS )); then ok "$n voimassa $na asti ($days pv)"
    else bad "$n vanhenee $na ($days pv < $CERT_MIN_DAYS)"; fi
  done
  unset t
else bad "vault_token puuttuu tai Vault ei käytettävissä"; fi

if (( RC == 0 )); then echo "Savutesti: OK"; else echo "Savutesti: VIKOJA (docs/runbook.md)"; fi
exit "$RC"
