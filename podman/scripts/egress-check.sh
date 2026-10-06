#!/usr/bin/env bash
# Todentaa ilmaraon verkkorajaukset keskuspalvelimella (palvelukäyttäjänä, stack käynnissä):
#   1. lego-kontista DVV:n ACME-palvelu VASTAA (LEGO_SERVER, välityspalvelimen kautta jos asetettu)
#   2. lego-kontista muut kohteet (yleinen internet, imagerekisterit) EIVÄT vastaa
#   3. nginx- ja Vault-konteista ei ole yhteyttä ulos
#   4. palvelukäyttäjänä isännältä muut kohteet eivät vastaa (nftables, meta skuid)
# "Vastaa" = TCP-yhteys syntyy (myös TLS-virhe tarkoittaa, että kohde tavoitettiin).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ACME_ENV=${ACME_ENV:-/etc/acme-podman/.env}
DENY_TARGETS=${EGRESS_DENY_TARGETS:-"https://1.1.1.1/ https://registry-1.docker.io/v2/ https://quay.io/ https://registry.access.redhat.com/ https://www.google.com/"}
TIMEOUT=${EGRESS_TIMEOUT:-8}
RC=0

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  echo "Ympäristö: ACME_ENV, EGRESS_DENY_TARGETS (välilyönnein), EGRESS_TIMEOUT"
  echo "Valinnat: --skip-host (ohita isäntätason tarkistus), --help"
}
SKIP_HOST=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --skip-host) SKIP_HOST=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

env_get() { sed -n "s/^$1=\([^ #]*\).*/\1/p" "$ACME_ENV" | tail -1; }
LEGO_SERVER=$(env_get LEGO_SERVER)
LEGO_IMAGE=$(env_get LEGO_IMAGE)
[[ -n "$LEGO_SERVER" && -n "$LEGO_IMAGE" ]] || { echo "egress-check: LEGO_SERVER tai LEGO_IMAGE puuttuu $ACME_ENV:stä" >&2; exit 2; }

ok() { printf '  [OK]   %s\n' "$*"; }
bad() { printf '  [VIKA] %s\n' "$*"; RC=1; }

# curl-paluukoodi -> tavoitettiinko kohde (5/6 = nimeä/välityspalvelinta ei ratkaistu,
# 7 = yhteys estetty/hylätty, 28 = aikakatkaisu). 125-127 = podmanin oma virhe: tarkistus
# ei ajautunut, joten tulos on vika eikä "estetty".
reached() { case "$1" in 5|6|7|28) return 1 ;; *) return 0 ;; esac; }
tool_error() { case "$1" in 125|126|127) return 0 ;; *) return 1 ;; esac; }

# blocked_check <kuvaus> <curl-koodi>: estetyksi odotettu yhteys
blocked_check() {
  if tool_error "$2"; then bad "$1: tarkistus ei ajautunut (podman $2). Onko kontti käynnissä?"
  elif reached "$2"; then bad "$1: kohde tavoitettiin (curl $2)"
  else ok "$1 estetty (curl $2)"; fi
}

curl_args=(-s -o /dev/null --max-time "$TIMEOUT")

lego_curl() {
  local rc=0
  ACME_ENV="$ACME_ENV" "$SCRIPT_DIR/acme-compose.sh" --profile jobs run --rm -T --entrypoint curl lego \
    "${curl_args[@]}" "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

container_curl() { # verkon nimiavaruus = annetun kontin
  local rc=0
  podman run --rm --log-driver none --network "container:$1" --entrypoint curl "$LEGO_IMAGE" \
    "${curl_args[@]}" "$2" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

echo "1. lego -> DVV ($LEGO_SERVER)"
rc=$(lego_curl "$LEGO_SERVER")
if [[ "$rc" == 0 ]]; then ok "DVV vastaa"
elif tool_error "$rc"; then bad "tarkistus ei ajautunut (podman $rc). Onko lego-image ladattu?"
elif reached "$rc"; then bad "DVV tavoitettiin, mutta curl palautti $rc (TLS/CA?). Tarkista ca-certificates ja välityspalvelin."
else bad "DVV ei vastaa (curl $rc). Tarkista palomuuri, --egress-allow, DNS ja HTTPS_PROXY."; fi

echo "2. lego -> muut kohteet (pitää olla estetty)"
for t in $DENY_TARGETS; do
  blocked_check "lego -> $t" "$(lego_curl "$t")"
done

echo "3. nginx ja Vault -> ulos (pitää olla estetty)"
for c in acme-nginx acme-vault; do
  if ! podman container exists "$c"; then bad "$c ei ole olemassa"; continue; fi
  for t in "$LEGO_SERVER" https://1.1.1.1/; do
    blocked_check "$c -> $t" "$(container_curl "$c" "$t")"
  done
done

if (( ! SKIP_HOST )); then
  echo "4. palvelukäyttäjä isännältä -> muut kohteet (nftables)"
  for t in $DENY_TARGETS; do
    rc=0; curl "${curl_args[@]}" "$t" >/dev/null 2>&1 || rc=$?
    blocked_check "isäntä ($(id -un)) -> $t" "$rc"
  done
fi

if (( RC == 0 )); then echo "Tulos: verkkorajaukset kunnossa"; else echo "Tulos: VIKOJA, katso [VIKA]-rivit (docs/verkko.md)"; fi
exit "$RC"
