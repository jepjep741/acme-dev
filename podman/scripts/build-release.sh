#!/usr/bin/env bash
# Julkaisupaketin rakennus ILMARAON ULKOPUOLELLA (rakennusympäristö, vaatii verkon). [VERKKO]
#
#   build-release.sh --version 1.0.0 --gpg-key <avain-ID/sormenjälki> [--out release] [--skip-scan] [--force]
#
# Tuottaa release/<versio>/:
#   images/{nginx,vault,lego}.oci.tar  imaget OCI-arkistoina, digestit säilyvät (IMAGES.txt)
#   bin/vault.exe                      Windows-agentti (HashiCorpin allekirjoittama SHA256SUMS tarkistettu)
#   podman/ windows/ linux/ docs/      ilman kehitys- ja testitiedostoja (compose.dev.yaml, tests/)
#   sbom/ scan/                        SBOM (syft, SPDX) ja haavoittuvuusraportit (trivy) jokaisesta imagesta
#   DEPENDENCIES.md CHANGELOG.md VERSION IMAGES.txt
#   SHA256SUMS + SHA256SUMS.asc        kaikki tiedostot; irrallinen GPG-allekirjoitus
# Ilmaraossa: import-release.sh tarkistaa allekirjoituksen ja summat ENNEN latausta.
# Allekirjoitusavaimen julkinen osa toimitetaan ilmarakoon ERILLÄÄN paketista (luottamusankkuri).
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
# shellcheck source=podman/versions.env
source "$ROOT/podman/versions.env"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
log() { printf 'build-release: %s\n' "$*" >&2; }
die() { log "VIRHE: $*"; exit 1; }

VERSION="" KEY="" OUT="$ROOT/release" SKIP_SCAN=0 FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --gpg-key) KEY=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --skip-scan) SKIP_SCAN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "--version x.y.z vaaditaan"
[[ -n "$KEY" ]] || die "--gpg-key vaaditaan (julkaisujen allekirjoitusavain)"
for t in podman gpg sha256sum python3 curl unzip; do command -v "$t" >/dev/null || die "$t puuttuu"; done
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || die "allekirjoitusavainta $KEY ei löydy (gpg --list-secret-keys)"

D="$OUT/$VERSION"
if [[ -e "$D" ]]; then (( FORCE )) || die "$D on jo olemassa (--force korvaa)"; rm -rf "$D"; fi
mkdir -p "$D"/{images,bin,sbom,scan}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

env_ref() { sed -n "s/^$1=\([^ #]*\).*/\1/p" "$ROOT/podman/.env.example"; }
NGINX_REF=$(env_ref NGINX_IMAGE); VAULT_REF=$(env_ref VAULT_IMAGE)
[[ "$NGINX_REF" == *@sha256:* && "$VAULT_REF" == *@sha256:* ]] || die ".env.example: NGINX_IMAGE/VAULT_IMAGE eivät ole digest-kiinnitettyjä"

# --- 1. Imaget ------------------------------------------------------------------
LEGO_TAG="localhost/acme-lego:$LEGO_IMAGE_TAG"
log "Rakennetaan $LEGO_TAG"
podman build -q --pull=missing \
  --build-arg UBI_IMAGE="$UBI_IMAGE" --build-arg LEGO_VERSION="$LEGO_VERSION" --build-arg LEGO_SHA256="$LEGO_SHA256" \
  --build-arg VAULT_VERSION="$VAULT_VERSION" --build-arg VAULT_SHA256="$VAULT_LINUX_SHA256" \
  -t "$LEGO_TAG" -f "$ROOT/podman/images/lego/Containerfile" "$ROOT/podman/images/lego" >/dev/null

skopeo() { podman run --rm --log-driver none -v "$D/images:/out:z" "$SKOPEO_IMAGE" "$@"; }
# Ulkoiset imaget suoraan rekisteristä: --preserve-digests (manifesti sellaisenaan -> digest-pin toimii ladattuna)
declare -A EXT_REF=([nginx]="$NGINX_REF" [vault]="$VAULT_REF")
for name in nginx vault; do
  ref=${EXT_REF[$name]}
  log "Kopioidaan $ref -> images/$name.oci.tar"
  skopeo copy -q --preserve-digests "docker://$ref" "oci-archive:/out/$name.oci.tar:${ref%@*}:acme-$VERSION"
done
log "Viedään $LEGO_TAG -> images/lego.oci.tar"
podman push -q --format oci "$LEGO_TAG" "oci-archive:$D/images/lego.oci.tar:$LEGO_TAG"

archive_digest() { tar -xOf "$1" index.json | python3 -c 'import sys,json;print(json.load(sys.stdin)["manifests"][0]["digest"])'; }
LEGO_REF="localhost/acme-lego@$(archive_digest "$D/images/lego.oci.tar")"
for name in nginx vault; do
  ref=${EXT_REF[$name]}
  [[ "$(archive_digest "$D/images/$name.oci.tar")" == "${ref#*@}" ]] || die "$name: arkiston digest ei vastaa kiinnitystä ${ref#*@}"
done
printf '%s\t%s\t%s\n' nginx "$NGINX_REF" images/nginx.oci.tar vault "$VAULT_REF" images/vault.oci.tar \
  lego "$LEGO_REF" images/lego.oci.tar > "$D/IMAGES.txt"

# --- 2. vault.exe (Windows) -------------------------------------------------------
log "Haetaan vault $VAULT_VERSION (windows_amd64) ja tarkistetaan HashiCorpin allekirjoitus"
base="https://releases.hashicorp.com/vault/$VAULT_VERSION"
ZIP="vault_${VAULT_VERSION}_windows_amd64.zip"
curl -fsSLo "$WORK/$ZIP" "$base/$ZIP"
curl -fsSLo "$WORK/SUMS" "$base/vault_${VAULT_VERSION}_SHA256SUMS"
curl -fsSLo "$WORK/SUMS.sig" "$base/vault_${VAULT_VERSION}_SHA256SUMS.sig"
curl -fsSLo "$WORK/hashicorp.asc" https://www.hashicorp.com/.well-known/pgp-key.txt
export GNUPGHOME_HC="$WORK/gnupg-hc"; mkdir -m 700 "$GNUPGHOME_HC"
GNUPGHOME="$GNUPGHOME_HC" gpg -q --import "$WORK/hashicorp.asc" 2>/dev/null
GNUPGHOME="$GNUPGHOME_HC" gpg --with-colons --fingerprint | grep -q "^fpr:::::::::$HASHICORP_GPG_FPR:" ||
  die "HashiCorpin avaimen sormenjälki ei täsmää ($HASHICORP_GPG_FPR)"
GNUPGHOME="$GNUPGHOME_HC" gpg -q --verify "$WORK/SUMS.sig" "$WORK/SUMS" 2>/dev/null || die "HashiCorpin SHA256SUMS-allekirjoitus ei kelpaa"
echo "$VAULT_WINDOWS_SHA256  $ZIP" | (cd "$WORK" && sha256sum -c --quiet -) || die "$ZIP: SHA256 ei täsmää versions.env:iin"
grep -q "^$VAULT_WINDOWS_SHA256  $ZIP$" "$WORK/SUMS" || die "versions.env:n SHA256 ei ole HashiCorpin SHA256SUMS:ssa"
unzip -q -o "$WORK/$ZIP" vault.exe -d "$D/bin"

# --- 3. Lähteet (ilman kehitys- ja testitiedostoja) -------------------------------
log "Kopioidaan lähteet"
mkdir -p "$D/podman"
(cd "$ROOT/podman" && tar --exclude=compose.dev.yaml --exclude=.env -cf - .) | tar -C "$D/podman" -xf -
cp -a "$ROOT/windows" "$ROOT/linux" "$ROOT/docs" "$D/"
cp "$ROOT/README.md" "$ROOT/release/DEPENDENCIES.md" "$ROOT/release/CHANGELOG.md" "$D/"
# Julkaisun .env.example: oma lego-image digestillä
sed -i "s|^LEGO_IMAGE=.*|LEGO_IMAGE=$LEGO_REF|" "$D/podman/.env.example"
printf '%s\n' "$VERSION" > "$D/VERSION"

# --- 4. SBOM ja haavoittuvuusskannaus ------------------------------------------------
if (( SKIP_SCAN )); then
  log "VAROITUS: --skip-scan: SBOM ja skannaus ohitettu (ei tuotantojulkaisuun)"
  echo "SBOM ja skannaus ohitettu (--skip-scan)" > "$D/scan/SUMMARY.txt"
else
  mkdir -p "$WORK/trivy-cache"
  : > "$D/scan/SUMMARY.txt"
  for name in nginx vault lego; do
    log "SBOM + skannaus: $name"
    podman run --rm --log-driver none -v "$D/images:/in:ro,z" "$SYFT_IMAGE" \
      "oci-archive:/in/$name.oci.tar" -o spdx-json -q > "$D/sbom/$name.spdx.json"
    # trivy --input lukee OCI-layout-hakemiston (ei oci-archive-tiedostoa): puretaan väliaikaisesti
    mkdir -p "$WORK/layout-$name"; tar -xf "$D/images/$name.oci.tar" -C "$WORK/layout-$name"
    podman run --rm --log-driver none -v "$WORK/layout-$name:/in:ro,z" -v "$WORK/trivy-cache:/root/.cache/trivy:z" "$TRIVY_IMAGE" \
      image --quiet --input /in --format json --scanners vuln > "$D/scan/$name.trivy.json"
    rm -rf "$WORK/layout-$name"
    python3 - "$name" "$D/scan/$name.trivy.json" >> "$D/scan/SUMMARY.txt" <<'PY'
import sys, json, collections
name, path = sys.argv[1], sys.argv[2]
d = json.load(open(path)); c = collections.Counter()
for r in d.get("Results") or []:
    for v in r.get("Vulnerabilities") or []:
        c[v.get("Severity", "UNKNOWN")] += 1
print(f"{name}: " + ", ".join(f"{k} {c.get(k,0)}" for k in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")))
PY
  done
  log "Haavoittuvuusyhteenveto:"; sed 's/^/  /' "$D/scan/SUMMARY.txt" >&2
fi

# --- 5. Tarkistussummat ja allekirjoitus ---------------------------------------------
(cd "$D" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.asc -printf '%P\n' | LC_ALL=C sort > "$WORK/files"
  xargs -d '\n' sha256sum < "$WORK/files" > SHA256SUMS)
gpg --batch --yes --local-user "$KEY" --armor --detach-sign --output "$D/SHA256SUMS.asc" "$D/SHA256SUMS"
gpg --armor --export "$KEY" > "$OUT/release-signing-key-$VERSION.asc"
(cd "$OUT" && tar -cf "acme-release-$VERSION.tar" "$VERSION")
log "Valmis: $D ($(du -sh "$D" | cut -f1)); siirtoon $OUT/acme-release-$VERSION.tar"
log "Allekirjoitusavaimen julkinen osa: $OUT/release-signing-key-$VERSION.asc (toimita ilmarakoon ERILLÄÄN)"
