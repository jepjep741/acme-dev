#!/usr/bin/env bash
# Julkaisupaketin tuonti ILMARAOSSA (root). Mitään ei ladata ennen kuin allekirjoitus ja kaikki
# tarkistussummat on todettu kelvollisiksi.
#
#   import-release.sh PAKETTIHAKEMISTO --pubkey julkaisuavain.asc [--user acmesvc] [--activate] [--verify-only]
#
#   1. kopio root-omisteiseen väliaikaishakemistoon (tarkistus tehdään kopiosta: ei TOCTOU-ikkunaa)
#   2. GPG-allekirjoitus (SHA256SUMS.asc) luotettua julkista avainta vasten (--pubkey, toimitettu
#      ilmarakoon ERILLÄÄN paketista) ja kaikki tiedostot SHA256SUMS:n mukaan; listaamattomat
#      tai puuttuvat tiedostot = virhe
#   3. siirto /opt/acme/releases/<versio> (root, vain luku), SELinux-kontekstit
#   4. imagejen lataus palvelukäyttäjälle (podman load) ja digestien tarkistus (IMAGES.txt)
#   5. /opt/acme/current -> uusi versio vain ensiasennuksessa tai --activate
# .env:iä ei muuteta: skripti tulostaa uudet image-viitteet (päivitys kontti kerrallaan).
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }
log() { printf 'import-release: %s\n' "$*" >&2; }
die() { log "VIRHE: $*"; exit 1; }

SRC="" PUBKEY="" SVC_USER=acmesvc ACTIVATE=0 VERIFY_ONLY=0
RELEASES=${ACME_RELEASES_DIR:-/opt/acme/releases}
CURRENT=${ACME_CURRENT_LINK:-/opt/acme/current}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkey) PUBKEY=$2; shift 2 ;;
    --user) SVC_USER=$2; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) SRC=$1; shift ;;
  esac
done
[[ -n "$SRC" && -d "$SRC" ]] || { usage >&2; exit 2; }
[[ -r "$PUBKEY" ]] || die "--pubkey: luotettu julkaisuavain vaaditaan"
SRC=$(cd "$SRC" && pwd)

# --- 1. Allekirjoitus ----------------------------------------------------------
verify_signature() {
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  [[ -r "$SRC/SHA256SUMS" && -r "$SRC/SHA256SUMS.asc" ]] || die "SHA256SUMS tai SHA256SUMS.asc puuttuu"
  if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$PUBKEY"; then gpg --dearmor < "$PUBKEY" > "$tmp/key.gpg"
  else cp "$PUBKEY" "$tmp/key.gpg"; fi
  gpgv --keyring "$tmp/key.gpg" "$SRC/SHA256SUMS.asc" "$SRC/SHA256SUMS" 2>"$tmp/gpgv.log" ||
    { sed 's/^/  /' "$tmp/gpgv.log" >&2; die "allekirjoitus EI kelpaa: pakettia ei käytetä"; }
  log "Allekirjoitus OK ($(grep -o 'using [A-Z]* key [0-9A-F]*' "$tmp/gpgv.log" | head -1))"
}

# --- 2. Tarkistussummat ja tiedostolista -----------------------------------------
verify_checksums() {
  (cd "$SRC" && sha256sum --quiet --strict -c SHA256SUMS) || die "tarkistussummat eivät täsmää: paketti on vioittunut tai muutettu"
  local extra
  extra=$(cd "$SRC" && LC_ALL=C comm -23 <(find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.asc -printf '%P\n' | LC_ALL=C sort) \
    <(awk '{print $2}' SHA256SUMS | LC_ALL=C sort))
  [[ -z "$extra" ]] || die "paketissa on tiedostoja, joita SHA256SUMS ei kata: $(echo "$extra" | paste -sd' ')"
  grep -qE '^[0-9a-f]{64}  \S' "$SRC/SHA256SUMS" || die "SHA256SUMS on tyhjä tai virheellinen"
  log "Tarkistussummat OK ($(wc -l < "$SRC/SHA256SUMS") tiedostoa)"
}

if (( VERIFY_ONLY )); then
  verify_signature
  verify_checksums
  VERSION=$(tr -d '[:space:]' < "$SRC/VERSION")
  log "Paketti $VERSION on kelvollinen (--verify-only). Tuonti tarkistaa kopion uudelleen."
  exit 0
fi

[[ $EUID -eq 0 ]] || die "aja rootina (tarkistus onnistuu ilman: --verify-only)"
id "$SVC_USER" >/dev/null 2>&1 || die "palvelukäyttäjä $SVC_USER puuttuu (install-host.sh install)"

# --- 3. Kopio ENSIN root-omisteiseen hakemistoon, tarkistus kopiosta ---------------
# Ei TOCTOU-ikkunaa: siirtomedialla olevaa pakettia ei käytetä tarkistuksen jälkeen, joten
# median kirjoitusoikeuden haltija ei voi vaihtaa tiedostoja tarkistuksen ja käytön välissä.
install -d -m 0755 "$RELEASES"
find "$RELEASES" -maxdepth 1 -name '.import.*' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true
STAGE=$(mktemp -d "$RELEASES/.import.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -a "$SRC/." "$STAGE/"
chown -R root:root "$STAGE"; chmod -R u=rwX,go=rX "$STAGE"
SRC=$STAGE
verify_signature
verify_checksums
VERSION=$(tr -d '[:space:]' < "$SRC/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "VERSION virheellinen"

DEST="$RELEASES/$VERSION"
if [[ -d "$DEST" ]]; then
  (cd "$DEST" && sha256sum --quiet --strict -c SHA256SUMS) || die "$DEST on olemassa mutta eroaa: poista se ensin tietoisesti"
  cmp -s "$DEST/SHA256SUMS" "$SRC/SHA256SUMS" || die "$DEST on eri paketti samalla versiolla: poista se ensin tietoisesti"
  log "$DEST on jo tuotu ja ehjä"
else
  chmod 0755 "$STAGE" "$STAGE"/podman/scripts/*.sh "$STAGE"/podman/images/lego/*.sh
  mv "$STAGE" "$DEST"
  trap - EXIT
  log "Kopioitu: $DEST"
fi
if command -v selinuxenabled >/dev/null && selinuxenabled; then restorecon -R "$DEST" || true; fi

# --- 4. Imaget ------------------------------------------------------------------------
uid=$(id -u "$SVC_USER")
as_svc() {
  if [[ "$SVC_USER" == root ]]; then "$@"
  else (cd / && runuser -u "$SVC_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"); fi
}
while IFS=$'\t' read -r name ref archive; do
  [[ -n "$name" ]] || continue
  log "Ladataan $name ($ref)"
  as_svc podman load -q -i "$DEST/$archive" >/dev/null
  as_svc podman image exists "$ref" || die "$name: ladattu image ei vastaa kiinnitettyä digestiä $ref"
done < "$DEST/IMAGES.txt"

# --- 5. Aktivointi ----------------------------------------------------------------
if [[ ! -e "$CURRENT" ]] || (( ACTIVATE )); then
  ln -sfn "$DEST" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"
  log "$CURRENT -> $DEST"
else
  log "$CURRENT osoittaa edelleen: $(readlink -f "$CURRENT") (aktivoi: --activate)"
fi

log "Julkaisun image-viitteet (.env päivitetään kontti kerrallaan, docs/paivitys-ilmarako.md):"
while IFS=$'\t' read -r name ref _; do
  [[ -n "$name" ]] || continue
  printf '  %s_IMAGE=%s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$name")" "$ref"
done < "$DEST/IMAGES.txt"
