#!/usr/bin/env bash
# /usr/local/sbin/lego-hook.sh  (root:root 0755)
# lego ajaa tämän --run-hook / --renew-hook -parametrilla vain kun varmenne
# on oikeasti myönnetty tai uusittu. lego antaa ympäristömuuttujat:
#   LEGO_CERT_PATH      .../certificates/<nimi>.crt   (palvelinvarmenne + välivarmenne)
#   LEGO_CERT_KEY_PATH  .../certificates/<nimi>.key
#   LEGO_CERT_DOMAIN    päädomain
set -euo pipefail
umask 077
source /etc/acme/vault.env          # VAULT_ADDR, VAULT_CACERT, VAULT_TOKEN (policy: acme-writer)

CRT="$LEGO_CERT_PATH"; KEY="$LEGO_CERT_KEY_PATH"
NAME="$(basename "$CRT" .crt)"
NOT_AFTER="$(openssl x509 -enddate -noout -in "$CRT" | cut -d= -f2)"
DOMAINS="$(openssl x509 -noout -ext subjectAltName -in "$CRT" | tail -n +2 | tr -d ' ' | sed 's/DNS://g')"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat "$CRT" "$KEY" > "$TMP/bundle.pem"

# PFX Windows/IIS-palvelimille. Satunnainen salasana jokaiselle myönnölle;
# salasana välitetään openssl:lle ympäristömuuttujana, ei komentoriviltä.
export PFXPW="$(openssl rand -base64 32)"
if [[ "${PFX_COMPAT:-modern}" == "legacy" ]]; then
  PBE=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)   # Windows Server 2016 ja vanhemmat
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

logger -t acme-deploy "Vaultiin päivitetty: $NAME ($DOMAINS), voimassa $NOT_AFTER asti"
