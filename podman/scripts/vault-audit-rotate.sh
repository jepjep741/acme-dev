#!/usr/bin/env bash
# Vaultin audit-lokin kierto (vault-audit-rotate.timer). Ajetaan palvelukäyttäjänä.
# Kierto tehdään kontin sisällä (tiedostot omistaa kontin vault-käyttäjä), minkä jälkeen
# SIGHUP saa Vaultin avaamaan audit.log:n uudelleen. Vanhat tiedostot pakataan ja
# yli AUDIT_KEEP_DAYS päivää vanhat poistetaan.
#
# HUOM: jos audit-laite ei voi kirjoittaa, Vault kieltäytyy palvelemasta pyyntöjä.
# Seuraa levytilaa: scripts/healthcheck.sh.
set -euo pipefail

CONTAINER=${VAULT_CONTAINER:-acme-vault}
KEEP_DAYS=${AUDIT_KEEP_DAYS:-30}
DRY_RUN=0

case "${1:-}" in
  -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; echo "Valinnat: --dry-run, ympäristö: AUDIT_KEEP_DAYS (oletus 30)"; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "Käyttö: $0 [--dry-run|--help]" >&2; exit 2 ;;
esac
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || { echo "vault-audit-rotate: AUDIT_KEEP_DAYS ei ole luku" >&2; exit 2; }

if ! podman container exists "$CONTAINER" || [[ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER")" != true ]]; then
  echo "vault-audit-rotate: $CONTAINER ei ole käynnissä, ohitetaan" >&2
  exit 0
fi

if (( DRY_RUN )); then
  podman exec "$CONTAINER" sh -c 'ls -l /vault/logs'
  echo "vault-audit-rotate: [dry-run] kierrettäisiin audit.log ja poistettaisiin yli $KEEP_DAYS pv vanhat" >&2
  exit 0
fi

ROTATED=$(podman exec "$CONTAINER" sh -c '
  cd /vault/logs || exit 1
  [ -s audit.log ] || exit 0
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mv audit.log "audit.log.$ts" && echo "audit.log.$ts"')

if [[ -n "$ROTATED" ]]; then
  podman kill --signal HUP "$CONTAINER" >/dev/null
  # Vault avaa uuden audit.log:n vasta SIGHUP:n jälkeen; pakataan vanha vasta sitten.
  sleep 2
  podman exec "$CONTAINER" sh -c "gzip -9 '/vault/logs/$ROTATED'"
  echo "vault-audit-rotate: kierretty $ROTATED" >&2
fi
podman exec "$CONTAINER" find /vault/logs -name 'audit.log.*.gz' -mtime "+$KEEP_DAYS" -print -delete |
  sed 's/^/vault-audit-rotate: poistettu /' >&2
