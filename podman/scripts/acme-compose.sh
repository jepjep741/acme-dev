#!/usr/bin/env bash
# podman-compose-kääre: vakiopolut tuotannossa, jotta systemd-yksiköt ja ylläpitäjä
# käyttävät aina samaa .env:iä ja compose-tiedostoa. Ajetaan palvelukäyttäjänä (acmesvc).
#
#   acme-compose.sh up -d
#   acme-compose.sh --profile jobs run --rm -T lego
#   acme-compose.sh ps
#
# Ympäristömuuttujat (oletukset):
#   ACME_DIR  julkaisun podman-hakemisto (tämän skriptin ylähakemisto, esim. /opt/acme/current/podman)
#   ACME_ENV  /etc/acme-podman/.env
#   ACME_COMPOSE_FILES  lisätiedostot välilyönnein (esim. "compose.eab.yaml")
set -euo pipefail

ACME_DIR=${ACME_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}
ACME_ENV=${ACME_ENV:-/etc/acme-podman/.env}
PC=${PODMAN_COMPOSE:-podman-compose}

case "${1:-}" in
  -h|--help)
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  "")
    echo "Käyttö: acme-compose.sh <podman-compose-komento> [args...]  (--help)" >&2
    exit 2 ;;
esac

[[ -r "$ACME_ENV" ]] || { echo "acme-compose: VIRHE: $ACME_ENV puuttuu tai ei ole luettavissa. Kopioi .env.example ja täytä." >&2; exit 1; }
[[ -r "$ACME_DIR/compose.yaml" ]] || { echo "acme-compose: VIRHE: $ACME_DIR/compose.yaml puuttuu." >&2; exit 1; }

FILES=(-f "$ACME_DIR/compose.yaml")
for f in ${ACME_COMPOSE_FILES:-}; do FILES+=(-f "$ACME_DIR/$f"); done

exec "$PC" --env-file "$ACME_ENV" "${FILES[@]}" "$@"
