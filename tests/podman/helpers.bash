# shellcheck shell=bash disable=SC2034  # osa muuttujista käytetään vain .bats-tiedostoissa
# Yhteiset apufunktiot podman-e2e-testeille (bats). Vain rakennus-/testiympäristö.
# Testit käyttävät käyttäjän rootless-podmania: kontit acme-*, salaisuudet vault_tls_key,
# vault_token, lego_eab_*. ÄLÄ aja samalla käyttäjällä, jolla on tuotantoasennus.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PODMAN_DIR="$ROOT/podman"
PC=${PODMAN_COMPOSE:-podman-compose}
# shellcheck source=podman/versions.env
source "$PODMAN_DIR/versions.env"
LEGO_IMAGE_REF="localhost/acme-lego:$LEGO_IMAGE_TAG"
CLIENT_IMAGE="localhost/acme-test-linux-client:1"

# Pebblen julkinen EAB-testiavain (tests/podman/pebble/pebble-config.json), ei salaisuus.
EAB_KID=kid-test
EAB_HMAC=zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W

# Testiympäristön tila säilyy tiedostossa, jotta setup_file ja testit jakavat sen.
T=${ACME_TEST_DIR:-${BATS_FILE_TMPDIR:-/tmp}/acme-e2e}
ENV_FILE="$T/dev.env"
export ACME_ENV="$ENV_FILE"
export GNUPGHOME="$T/gnupg"

compose() {
  (cd "$PODMAN_DIR" && "$PC" --env-file "$ENV_FILE" -f compose.yaml -f compose.dev.yaml "$@")
}

compose_eab() {
  (cd "$PODMAN_DIR" && "$PC" --env-file "$ENV_FILE" -f compose.yaml -f compose.dev.yaml -f compose.eab.yaml "$@")
}

# Lego-ajo kuten acme-renew.service (ilman TTY:tä). Lisäargumentit ennen palvelun nimeä.
run_lego() { compose --profile jobs run --rm -T "$@" lego; }

# Vault-komento vault-kontissa testin root-tokenilla. Token kulkee stdinin ensimmäisenä
# rivinä (ei komentoriville eikä podman inspectiin); loput stdinistä menee vaultille.
# Kutsujan on aina ohjattava stdin (esim. </dev/null).
vault_root() {
  { cat "$T/root-token"; printf '\n'; cat; } |
    podman exec -i acme-vault sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"
}

wait_for() { # wait_for <sekuntia> <komento...>
  local n=$1; shift
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

write_dev_env() {
  mkdir -p "$T/config/tls" "$T/dev"
  cat > "$ENV_FILE" <<EOF
NGINX_IMAGE=docker.io/nginxinc/nginx-unprivileged@sha256:bfcf1250dae73fb5dafe18b9fa64d033441510c5a2fc7a11cf8003087890301b
VAULT_IMAGE=docker.io/hashicorp/vault@sha256:8af37ae9d45e4a0fac48ab700e0d99efc4c2d6cd84354a869f2147f1d3abab46
LEGO_IMAGE=$LEGO_IMAGE_REF
PEBBLE_IMAGE=$PEBBLE_IMAGE
CHALLTESTSRV_IMAGE=$CHALLTESTSRV_IMAGE
ACME_CONF_DIR=$T/config
DEV_DIR=$T/dev
NGINX_PUBLISH=127.0.0.1:18080
VAULT_BIND_IP=127.0.0.1
VAULT_PUBLISH_PORT=18200
VAULT_API_ADDR=https://vault.test:8200
LEGO_SERVER=https://pebble:14000/dir
LEGO_EMAIL=test@example.org
KEY_TYPE=RSA2048
RENEW_DAYS=30
PFX_COMPAT=modern
HTTPS_PROXY=
NO_PROXY=
BACKUP_DIR=$T/backup
RETENTION_DAYS=30
BACKUP_GPG_KEYFILE=$T/pgp.asc
EOF
  install -d -m 700 "$T/backup"
  printf '%s\n' "web   web.acme.test" "multi a.acme.test,b.acme.test" > "$T/config/certs.conf"
}

extract_pebble_ca() {
  local c; c=$(podman create "$PEBBLE_IMAGE")
  podman export "$c" | tar -xO test/certs/pebble.minica.pem > "$T/dev/pebble-ca.pem"
  podman rm "$c" >/dev/null
}

# Testin PGP-avain (avainosien ja root-tokenin salaus, varmuuskopion salaus). Ei salasanaa.
make_test_pgp() {
  export GNUPGHOME="$T/gnupg"; install -d -m 700 "$GNUPGHOME"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "acme e2e <e2e@example.org>" rsa3072 encrypt never 2>/dev/null
  gpg --batch --armor --export e2e@example.org > "$T/pgp.asc"
}

pgp_decrypt_b64() { base64 -d | gpg --batch --quiet --decrypt 2>/dev/null; }

# N:s salattu avainosa selväkielisenä (vain testi)
unseal_key() {
  python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["unseal_keys_b64_pgp"][int(sys.argv[2])])' \
    "$T/keys.json" "$1" | pgp_decrypt_b64
}

# TOTP-koodi otpauth-URL:sta (RFC 6238, SHA1, 6 numeroa, 30 s)
totp_code() {
  python3 - "$(cat "$T/totp.url")" <<'PY'
import sys,hmac,hashlib,struct,time,base64,urllib.parse as u
s=u.parse_qs(u.urlparse(sys.argv[1]).query)["secret"][0]
k=base64.b32decode(s+"="*((8-len(s)%8)%8)); c=int(time.time())//30
h=hmac.new(k,struct.pack(">Q",c),hashlib.sha1).digest(); o=h[-1]&15
print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))
PY
}

# Vault hylkää jo käytetyn koodin: odota tarvittaessa seuraavaa 30 s jaksoa.
fresh_totp() {
  local c last=""
  [[ -r "$T/totp-last" ]] && last=$(cat "$T/totp-last")
  c=$(totp_code)
  while [[ "$c" == "$last" ]]; do sleep 2; c=$(totp_code); done
  printf '%s' "$c" > "$T/totp-last"
  printf '%s' "$c"
}

ADMIN_USER=e2e.admin
ADMIN_PW='e2e-salasana-pitka-1'

# Vault tuotantoskripteillä: init (5/3, PGP) -> unseal -> configure -> ylläpitäjä -> palvelutokenit.
# Root-token jätetään testin ajaksi (revoke-root testataan viimeisenä).
bootstrap_vault() {
  local s="$PODMAN_DIR/scripts" k
  wait_for 60 podman exec acme-vault sh -c 'vault status; [ $? -ne 1 ]' || return 1
  make_test_pgp
  k="$T/pgp.asc"
  "$s/vault-init.sh" init --shares 5 --threshold 3 --pgp-keys "$k,$k,$k,$k,$k" --root-pgp-key "$k" \
    --out "$T/keys.json" --no-configure
  python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["root_token_pgp"])' "$T/keys.json" |
    pgp_decrypt_b64 > "$T/root-token"
  chmod 600 "$T/root-token"
  { unseal_key 0; echo; unseal_key 1; echo; unseal_key 2; echo; } | "$s/vault-unseal.sh"
  export VAULT_ADMIN_TOKEN_FILE="$T/root-token"
  "$s/vault-init.sh" configure
  printf '%s\n%s\n' "$ADMIN_PW" "$ADMIN_PW" | "$s/vault-init.sh" admin-add "$ADMIN_USER" --totp-out "$T/totp.url"
  "$s/secrets.sh" vault-token
  "$s/secrets.sh" snapshot-token
  unset VAULT_ADMIN_TOKEN_FILE
}

# podman-compose 1.5 "down -v" ei poista volyymeja, joita käyttävät vain run --rm -kontit
# (acme_lego-data), joten testit poistavat projektin volyymit itse.
remove_volumes() {
  podman volume rm -f acme_lego-data acme_acme-webroot acme_vault-data acme_vault-audit >/dev/null 2>&1 || true
}

setup_dev_stack() {
  compose --profile jobs down -v >/dev/null 2>&1 3>&- || true
  remove_volumes
  rm -rf "$T"; mkdir -p "$T"
  write_dev_env
  extract_pebble_ca
  "$PODMAN_DIR/scripts/tls-init.sh" generate --dir "$T/config/tls" --dns vault.test --ip 127.0.0.1 >/dev/null 2>&1
  printf '%s' "$EAB_KID" | podman secret create --replace lego_eab_kid - >/dev/null
  printf '%s' "$EAB_HMAC" | podman secret create --replace lego_eab_hmac - >/dev/null
  # vault_token luodaan bootstrapissa; compose vaatii sen olemassaolon jo up-vaiheessa.
  printf 'placeholder' | podman secret create --replace vault_token - >/dev/null
  # 3>&- : bats odottaa muuten taustalle jääviä prosesseja (conmon), jotka perivät FD 3:n.
  compose up -d >/dev/null 2>&1 3>&-
  wait_for 60 curl -sf http://127.0.0.1:18080/healthz || return 1
  # Pebble ratkaisee kaikki testidomainit nginxin osoitteeseen edge-verkossa.
  local ip
  ip=$(podman inspect acme-nginx --format '{{(index .NetworkSettings.Networks "acme_edge").IPAddress}}')
  curl -sf -X POST -d "{\"ip\":\"$ip\"}" http://127.0.0.1:8055/set-default-ipv4 >/dev/null
  bootstrap_vault
  date '+%Y-%m-%d %H:%M:%S' > "$T/started"
}

teardown_dev_stack() {
  [[ -n "${KEEP_STACK:-}" ]] && return 0
  compose --profile jobs down -v >/dev/null 2>&1 || true
  remove_volumes
  podman secret rm vault_tls_key vault_token snapshot_token lego_eab_kid lego_eab_hmac >/dev/null 2>&1 || true
  rm -rf "$T"
}

# Vaultin kentän arvo testin root-tokenilla
kv_field() { vault_root kv get -field="$2" "secret/certs/$1" </dev/null; }
kv_version() { vault_root kv metadata get -format=json "secret/certs/$1" </dev/null |
  sed -n 's/.*"current_version": *\([0-9]*\).*/\1/p'; }
