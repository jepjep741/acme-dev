#!/usr/bin/env bash
# Konttiversio keskus/lego-hook.sh:sta (lego v5 --deploy-hook).
# lego ajaa tämän vain, kun varmenne on oikeasti myönnetty tai uusittu, ja antaa:
#   LEGO_HOOK_CERT_PATH      .../certificates/<nimi>.crt   (palvelinvarmenne + välivarmenne)
#   LEGO_HOOK_CERT_KEY_PATH  .../certificates/<nimi>.key   (PKCS#8)
#   LEGO_HOOK_CERT_NAME      <nimi> (--cert.name)
# Vault-token luetaan tiedostosta /run/secrets/vault_token (policy: acme-writer).
set -euo pipefail
umask 077

log() { printf 'acme-deploy: %s\n' "$*" >&2; }

case "${1:-}" in
  -h|--help) echo "Käyttö: lego ajaa tämän --deploy-hookina (LEGO_HOOK_*-muuttujat)."; exit 0 ;;
esac

CRT="${LEGO_HOOK_CERT_PATH:?LEGO_HOOK_CERT_PATH puuttuu}"
KEY="${LEGO_HOOK_CERT_KEY_PATH:?LEGO_HOOK_CERT_KEY_PATH puuttuu}"
NAME="${LEGO_HOOK_CERT_NAME:-$(basename "$CRT" .crt)}"
[[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { log "virheellinen varmenteen nimi: $NAME"; exit 1; }

VAULT_TOKEN="$(tr -d '\r\n' < "${SECRETS_DIR:-/run/secrets}/vault_token")"
export VAULT_TOKEN

NOT_AFTER="$(openssl x509 -enddate -noout -in "$CRT" | cut -d= -f2)"
DOMAINS="$(openssl x509 -noout -ext subjectAltName -in "$CRT" | tail -n +2 | tr -d ' ' | sed 's/DNS://g')"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat "$CRT" "$KEY" > "$TMP/bundle.pem"

# PFX Windows/IIS-palvelimille. Satunnainen salasana jokaiselle myönnölle;
# salasana välitetään openssl:lle ympäristömuuttujana, ei komentoriviltä.
PFXPW="$(openssl rand -base64 32)"
export PFXPW
if [[ "${PFX_COMPAT:-modern}" == "legacy" ]]; then
  # Windows Server 2016 ja vanhemmat. OpenSSL 3: 3DES/SHA1-PBE vaatii legacy-providerin.
  PBE=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -legacy)
else
  PBE=(-keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256)     # Windows Server 2019 1809+
fi
openssl pkcs12 -export -in "$CRT" -inkey "$KEY" -name "$NAME" "${PBE[@]}" \
  -passout env:PFXPW -out "$TMP/cert.pfx"
base64 -w0 "$TMP/cert.pfx" > "$TMP/pfx.b64"
printf '%s' "$PFXPW" > "$TMP/pfx.pw"; unset PFXPW

vault kv put "secret/certs/$NAME" \
  fullchain=@"$CRT" \
  key=@"$KEY" \
  bundle=@"$TMP/bundle.pem" \
  pfx_b64=@"$TMP/pfx.b64" \
  pfx_password=@"$TMP/pfx.pw" \
  not_after="$NOT_AFTER" \
  domains="$DOMAINS" >/dev/null

# Voimassaolo myös metadataan (ISO 8601): valvonta (smoke-test.sh) lukee sen acme-writer-
# tokenilla ilman pääsyä varmenteen avaimeen.
NOT_AFTER_ISO="$(date -u -d "$NOT_AFTER" +%Y-%m-%dT%H:%M:%SZ)"
vault kv metadata patch -custom-metadata=not_after="$NOT_AFTER_ISO" -custom-metadata=domains="$DOMAINS" \
  "secret/certs/$NAME" >/dev/null

log "Vaultiin päivitetty: $NAME ($DOMAINS), voimassa $NOT_AFTER asti"
