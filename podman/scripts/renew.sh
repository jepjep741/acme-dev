#!/usr/bin/env bash
# ACME-uusinta lukituksella (acme-renew.service; myös käsiajoon).
#   renew.sh [lisäargumentit podman-compose run -komennolle, esim. -e RENEW_DAYS=3650]
# Lukitus estää samanaikaisen uusinnan ja varmuuskopion (lib.sh: acme_job_lock).
set -euo pipefail
LOG_TAG=acme-renew
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
case "${1:-}" in -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
acme_job_lock uusinta
exec "$LIB_DIR/acme-compose.sh" --profile jobs run --rm -T "$@" lego
