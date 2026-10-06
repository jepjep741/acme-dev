#!/usr/bin/env bash
# Keskuksen varmuuskopio (vault-snapshot.timer, palvelukäyttäjänä):
#   vault.snap        Vaultin raft-snapshot (salattu Vaultin avaimella: palautus vaatii avainosat)
#   lego-data.tar     legon ACME-tili ja varmenteet (yksityiset avaimet!) -> .gpg jos BACKUP_GPG_KEYFILE
#   config.tar        /etc/acme-podman ilman tls/private-hakemistoa (.env, certs.conf, TLS-varmenteet)
#   SHA256SUMS
# Kohde: BACKUP_DIR/<UTC-aika>/ (0700). Yli RETENTION_DAYS vanhat poistetaan.
# Asetukset .env:stä: BACKUP_DIR, RETENTION_DAYS, BACKUP_GPG_KEYFILE (julkinen avain, valinnainen).
# Token: podman secret snapshot_token (policy snapshot; secrets.sh snapshot-token).
set -euo pipefail
LOG_TAG=backup
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; echo "Valinnat: --dry-run, --help"; }
DRY_RUN=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

BACKUP_DIR=$(env_get BACKUP_DIR); BACKUP_DIR=${BACKUP_DIR:-/srv/acme-backup}
RETENTION_DAYS=$(env_get RETENTION_DAYS); RETENTION_DAYS=${RETENTION_DAYS:-30}
GPG_KEYFILE=$(env_get BACKUP_GPG_KEYFILE)
CONF_DIR=$(env_get ACME_CONF_DIR); CONF_DIR=${CONF_DIR:-/etc/acme-podman}
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS ei ole luku"
[[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] || die "BACKUP_DIR $BACKUP_DIR puuttuu tai ei ole kirjoitettavissa"
[[ -z "$GPG_KEYFILE" || -r "$GPG_KEYFILE" ]] || die "BACKUP_GPG_KEYFILE $GPG_KEYFILE ei ole luettavissa"
vault_running || die "$VAULT_CONTAINER ei ole käynnissä"
vault_is_sealed && die "Vault on sinetöity: snapshotia ei voi ottaa. Avaa: vault-unseal.sh"
podman secret exists snapshot_token || die "snapshot_token puuttuu: secrets.sh snapshot-token"

TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$BACKUP_DIR/$TS"; TMP="$BACKUP_DIR/.$TS.tmp"
if (( DRY_RUN )); then
  log "[dry-run] kohde $DEST: vault.snap, lego-data.tar${GPG_KEYFILE:+.gpg}, config.tar; säilytys $RETENTION_DAYS pv"
  exit 0
fi
acme_job_lock varmuuskopio
umask 077
mkdir "$TMP"; trap 'rm -rf "$TMP"' EXIT

# 1. Raft-snapshot: token stdinin 1. rivinä, snapshot stdoutiin
get_secret snapshot_token | { IFS= read -r t; printf '%s\n' "$t"; } |
  podman exec -i "$VAULT_CONTAINER" sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN
    f=/tmp/backup-$$.snap; vault operator raft snapshot save "$f" >/dev/null && cat "$f"; rc=$?; rm -f "$f"; exit $rc' \
  > "$TMP/vault.snap"
[[ -s "$TMP/vault.snap" ]] || die "raft-snapshot on tyhjä"

# 2. lego-data (sisältää yksityiset avaimet)
podman volume export acme_lego-data > "$TMP/lego-data.tar"
if [[ -n "$GPG_KEYFILE" ]]; then
  gpg --batch --yes --quiet --trust-model always --recipient-file "$GPG_KEYFILE" \
    --output "$TMP/lego-data.tar.gpg" --encrypt "$TMP/lego-data.tar"
  shred -u "$TMP/lego-data.tar" 2>/dev/null || rm -f "$TMP/lego-data.tar"
else
  log "VAROITUS: BACKUP_GPG_KEYFILE puuttuu: lego-data.tar (yksityiset avaimet) tallennetaan salaamattomana (hakemisto 0700)."
fi

# 3. Konfiguraatio ilman CA:n yksityistä avainta
tar -C "$CONF_DIR" --exclude='./tls/private' -cf "$TMP/config.tar" .

(cd "$TMP" && sha256sum -- * > SHA256SUMS)
mv "$TMP" "$DEST"; trap - EXIT
log "Varmuuskopio valmis: $DEST ($(du -sh "$DEST" | cut -f1))"

# 4. Säilytysaika (vain tämän skriptin luomat hakemistot)
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20[0-9][0-9][01][0-9][0-3][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' \
  -mtime "+$RETENTION_DAYS" -print -exec rm -rf {} + | sed 's/^/backup: poistettu vanha /' >&2
