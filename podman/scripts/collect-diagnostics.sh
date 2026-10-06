#!/usr/bin/env bash
# Kerää lokit ja tilatiedot yhteen arkistoon tukea varten, ILMAN SALAISUUKSIA (palvelukäyttäjänä).
#
#   collect-diagnostics.sh [--out HAKEMISTO] [--since "2 days ago"] [--audit-lines N]
#
# Sisältö: julkaisu ja käyttöjärjestelmä, healthcheck, podman (versio, info, kontit, imaget,
# volyymit, verkot, salaisuuksien NIMET), compose-konfiguraatio, .env ja certs.conf, journald-lokit
# (acme-*), käyttäjän systemd-yksiköt ja ajastimet, Vaultin tila, levytila ja aika.
# Audit-lokia ei oteta oletuksena (--audit-lines N ottaa N viimeistä riviä; arvot ovat HMAC:ttuja).
#
# Suojaus: 1) tunnetut salaisuusmuodot korvataan (<POISTETTU>); 2) ennen pakkausta jokaisen podman
# secretin TODELLINEN arvo haetaan ja sitä etsitään kaikista tiedostoista: jos löytyy, arkistoa ei
# luoda. Tarkista arkisto silti ennen kuin viet sen ulos.
set -euo pipefail
LOG_TAG=diagnostics
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

OUT=/tmp SINCE="2 days ago" AUDIT_LINES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --since) SINCE=$2; shift 2 ;;
    --audit-lines) AUDIT_LINES=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Käyttö: $0 [--out DIR] [--since AIKA] [--audit-lines N]" >&2; exit 2 ;;
  esac
done
[[ "$AUDIT_LINES" =~ ^[0-9]+$ ]] || die "--audit-lines ei ole luku"
[[ -d "$OUT" && -w "$OUT" ]] || die "$OUT ei ole kirjoitettava hakemisto"

umask 077
TS=$(date -u +%Y%m%dT%H%M%SZ)
NAME="acme-diag-$(hostname -s)-$TS"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
D="$WORK/$NAME"; mkdir "$D"
SCRIPTS="$LIB_DIR"

cap() { # cap <tiedosto> <komento...>: tuloste ja virheet talteen, virhe ei keskeytä
  local f="$D/$1"; shift
  { echo "\$ $*"; "$@" 2>&1 || echo "(paluukoodi $?)"; } > "$f"
}

cap meta.txt sh -c 'date -u; hostname; uname -a; cat /etc/os-release; readlink -f /opt/acme/current; id'
cap healthcheck.txt "$SCRIPTS/healthcheck.sh"
cap podman-version.txt podman version
cap podman-info.txt podman info
cap podman-ps.txt podman ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
cap podman-images.txt podman images --digests
cap podman-volumes.txt podman volume ls
cap podman-networks.txt sh -c 'podman network ls; podman network inspect acme_edge'
cap podman-secrets.txt podman secret ls --format '{{.Name}}\t{{.CreatedAt}}'
for c in acme-nginx acme-vault; do cap "inspect-$c.json" podman inspect "$c"; done
cap compose-config.txt "$SCRIPTS/acme-compose.sh" config
[[ -r "$ACME_ENV" ]] && cp "$ACME_ENV" "$D/env.txt"
conf=$(env_get ACME_CONF_DIR); conf=${conf:-/etc/acme-podman}
[[ -r "$conf/certs.conf" ]] && cp "$conf/certs.conf" "$D/certs.conf"
cap tls-vault-crt.txt sh -c "openssl x509 -in '$conf/tls/vault.crt' -noout -subject -issuer -dates -ext subjectAltName"
cap vault-status.json podman exec acme-vault vault status -format=json
cap journal.txt journalctl --user --since "$SINCE" --no-pager -o short-iso \
  -t acme-renew -t acme-deploy -t acme-vault -t acme-nginx -t vault-audit-rotate -t backup
cap systemd-units.txt sh -c 'systemctl --user list-units "acme-*" "vault-*" --all --no-pager; systemctl --user list-timers --all --no-pager'
for u in acme-stack.service acme-renew.service vault-snapshot.service vault-audit-rotate.service; do
  cap "status-$u.txt" systemctl --user status "$u" --no-pager -n 50
done
cap disk.txt sh -c "df -h; du -sh \"\$HOME/.local/share/containers\" 2>/dev/null"
cap time.txt sh -c 'date -u; timedatectl 2>/dev/null; chronyc tracking 2>/dev/null'
cap selinux.txt sh -c 'getenforce 2>/dev/null; ls -Zd /opt/acme /etc/acme-podman 2>/dev/null'
if (( AUDIT_LINES > 0 )); then
  cap audit-tail.jsonl podman exec acme-vault tail -n "$AUDIT_LINES" /vault/logs/audit.log
fi

# 1) Tunnettujen salaisuusmuotojen korvaus
find "$D" -type f -print0 | xargs -0 sed -i -E \
  -e 's/hv[sbr]\.[A-Za-z0-9_-]{20,}/<POISTETTU>/g' \
  -e 's/\bs\.[A-Za-z0-9]{24}\b/<POISTETTU>/g' \
  -e 's/("(client_token|accessor|secret_id|wrapping_token|token|password|pfx_password|pfx_b64|key|hmac)"[[:space:]]*:[[:space:]]*")[^"]+"/\1<POISTETTU>"/g' \
  -e 's/((password|secret_id|token|hmac|kid)=)[^[:space:]&"]+/\1<POISTETTU>/Ig'
# Yksityiset avaimet kokonaan pois
find "$D" -type f -print0 | xargs -0 sed -i -E '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\<POISTETTU YKSITYINEN AVAIN>'

# 2) Todellisten salaisuusarvojen tarkistus (podman secretit)
leak=0
for s in $(podman secret ls --format '{{.Name}}' 2>/dev/null); do
  while IFS= read -r line; do
    [[ ${#line} -ge 12 ]] || continue
    [[ "$line" == -----* ]] && continue
    if grep -rqF -- "$line" "$D"; then
      log "VIRHE: salaisuuden $s arvo löytyi kerätyistä tiedoista ($(grep -rlF -- "$line" "$D" | sed "s|$D/||" | paste -sd,))"
      leak=1
    fi
  done < <(get_secret "$s" 2>/dev/null || true)
done
(( leak == 0 )) || die "arkistoa ei luotu, koska siihen olisi päätynyt salaisuus. Ilmoita kehittäjille."

tar -C "$WORK" -czf "$OUT/$NAME.tar.gz" "$NAME"
chmod 0600 "$OUT/$NAME.tar.gz"
log "Valmis: $OUT/$NAME.tar.gz (tarkista sisältö ennen vientiä: tar -tzvf)"
printf '%s\n' "$OUT/$NAME.tar.gz"
