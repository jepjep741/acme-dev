#!/usr/bin/env bash
# Keskuksen tilan tarkistus valvontaa varten (palvelukäyttäjänä). Toimii täysin offline.
# Paluukoodi Nagios-tyyliin: 0 OK, 1 VAROITUS, 2 KRIITTINEN. Ei tulosta salaisuuksia.
#
#   healthcheck.sh [--quiet]     --quiet: vain yhteenvetorivi
# Rajat (ympäristö): CERT_WARN_DAYS=14 CERT_CRIT_DAYS=7 RENEW_WARN_HOURS=36 BACKUP_WARN_HOURS=36
set -euo pipefail
LOG_TAG=healthcheck
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

CERT_WARN_DAYS=${CERT_WARN_DAYS:-14}
CERT_CRIT_DAYS=${CERT_CRIT_DAYS:-7}
RENEW_WARN_HOURS=${RENEW_WARN_HOURS:-36}
BACKUP_WARN_HOURS=${BACKUP_WARN_HOURS:-36}
QUIET=0
case "${1:-}" in
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --quiet) QUIET=1 ;;
  "") ;;
  *) echo "Käyttö: $0 [--quiet|--help]" >&2; exit 2 ;;
esac

RC=0 LINES=()
res() { # res <0|1|2> <viesti>
  local tag=OK; (( $1 == 1 )) && tag=VAROITUS; (( $1 == 2 )) && tag=KRIITTINEN
  LINES+=("$(printf '  [%-10s] %s' "$tag" "$2")")
  (( $1 > RC )) && RC=$1
  return 0
}
now=$(date +%s)

# Kontit
for c in acme-nginx acme-vault; do
  if ! podman container exists "$c"; then res 2 "$c puuttuu"; continue; fi
  st=$(podman inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$c")
  case "$st" in
    "running healthy") res 0 "$c: käynnissä, healthy" ;;
    running*)
      # Vaultin "unhealthy" = sinetöity; se raportoidaan Vault-osiossa
      if [[ "$c" == acme-vault ]]; then res 0 "$c: käynnissä (${st#running })"; else res 1 "$c: $st"; fi ;;
    *) res 2 "$c: $st" ;;
  esac
done

# Vault
if vault_running; then
  if js=$(vault_status_json 2>/dev/null); then
    init=$(json_get 'd["initialized"]' <<< "$js"); sealed=$(json_get 'd["sealed"]' <<< "$js")
    if [[ "$init" != True ]]; then res 2 "Vault: ALUSTAMATON (vault-init.sh init)"
    elif [[ "$sealed" == True ]]; then res 2 "Vault: SINETÖITY - agentit eivät saa varmenteita (vault-unseal.sh)"
    else res 0 "Vault: avattu ($(json_get 'd["version"]' <<< "$js"))"; fi
  else res 2 "Vault: ei vastaa"; fi
fi

# Viimeisin onnistunut uusinta ja varmenteiden voimassaolo (lego-data, vain luku)
img=$(env_get LEGO_IMAGE)
if [[ -n "$img" ]] && podman volume exists acme_lego-data; then
  info=$(podman run --rm --log-driver none --network none -v acme_lego-data:/d:ro --entrypoint sh "$img" -c '
    cat /d/last-success 2>/dev/null || echo -
    for f in /d/certificates/*.crt; do [ -e "$f" ] || continue
      case "$f" in *.issuer.crt) continue ;; esac
      echo "$(basename "$f" .crt) $(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)"; done' 2>/dev/null || true)
  last=$(head -1 <<< "$info")
  if [[ "$last" == - || -z "$last" ]]; then res 1 "uusinta: ei onnistunutta ajoa vielä"
  else
    age=$(( (now - $(date -d "$last" +%s)) / 3600 ))
    if (( age > RENEW_WARN_HOURS )); then res 1 "uusinta: viimeisin onnistunut $last ($age h sitten). journalctl --user -t acme-renew"
    else res 0 "uusinta: viimeisin onnistunut $last"; fi
  fi
  while read -r name end; do
    [[ -n "$name" ]] || continue
    days=$(( ($(date -d "$end" +%s) - now) / 86400 ))
    if (( days < CERT_CRIT_DAYS )); then res 2 "varmenne $name vanhenee $days pv:n päästä ($end)"
    elif (( days < CERT_WARN_DAYS )); then res 1 "varmenne $name vanhenee $days pv:n päästä ($end)"
    else res 0 "varmenne $name voimassa $days pv"; fi
  done < <(tail -n +2 <<< "$info")
fi

# Varmuuskopio
bdir=$(env_get BACKUP_DIR); bdir=${bdir:-/srv/acme-backup}
if [[ -d "$bdir" ]]; then
  latest=$(find "$bdir" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1)
  if [[ -z "$latest" ]]; then res 1 "varmuuskopio: ei yhtään ($bdir)"
  else
    age=$(( (now - ${latest%%.*}) / 3600 ))
    if (( age > BACKUP_WARN_HOURS )); then res 1 "varmuuskopio: uusin ${latest#* } ($age h sitten)"
    else res 0 "varmuuskopio: uusin ${latest#* }"; fi
  fi
  use=$(df -P "$bdir" | awk 'NR==2{gsub("%","",$5); print $5}')
  if (( use >= 90 )); then res 1 "levytila: $bdir ${use}% käytössä"; else res 0 "levytila: $bdir ${use}%"; fi
fi

# Ajastimet (jos käyttäjän systemd on käytettävissä)
if systemctl --user is-system-running >/dev/null 2>&1 || systemctl --user list-timers >/dev/null 2>&1; then
  for t in acme-renew.timer vault-snapshot.timer vault-audit-rotate.timer; do
    if systemctl --user is-active --quiet "$t" 2>/dev/null; then res 0 "ajastin $t aktiivinen"
    elif systemctl --user cat "$t" >/dev/null 2>&1; then res 1 "ajastin $t ei ole aktiivinen"; fi
  done
fi

summary=(OK VAROITUS KRIITTINEN)
echo "Keskuksen tila: ${summary[$RC]}"
(( QUIET )) || printf '%s\n' "${LINES[@]}"
exit "$RC"
