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
EOF
  printf '%s\n' "web   web.acme.test" "multi a.acme.test,b.acme.test" > "$T/config/certs.conf"
}

extract_pebble_ca() {
  local c; c=$(podman create "$PEBBLE_IMAGE")
  podman export "$c" | tar -xO test/certs/pebble.minica.pem > "$T/dev/pebble-ca.pem"
  podman rm "$c" >/dev/null
}

# Testi-Vault: 1/1 avainosa (VAIN testi), KV v2, acme-writer, periodic-token -> podman secret.
bootstrap_vault() {
  wait_for 60 podman exec acme-vault sh -c 'vault status; [ $? -ne 1 ]' || return 1
  podman exec acme-vault vault operator init -key-shares=1 -key-threshold=1 -format=json > "$T/init.json"
  chmod 600 "$T/init.json"
  sed -n 's/.*"root_token": *"\([^"]*\)".*/\1/p' "$T/init.json" > "$T/root-token"
  tr -d '\n ' < "$T/init.json" | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p' | tr -d '\n' |
    podman exec -i acme-vault vault write sys/unseal key=- >/dev/null
  wait_for 30 podman exec acme-vault vault status || return 1
  vault_root secrets enable -path=secret -version=2 kv </dev/null
  vault_root policy write acme-writer - < "$PODMAN_DIR/vault/policies/acme-writer.hcl"
  vault_root token create -policy=acme-writer -period=768h -orphan -field=token </dev/null |
    podman secret create --replace vault_token - >/dev/null
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
  podman secret rm vault_tls_key vault_token lego_eab_kid lego_eab_hmac >/dev/null 2>&1 || true
  rm -rf "$T"
}

# Vaultin kentän arvo testin root-tokenilla
kv_field() { vault_root kv get -field="$2" "secret/certs/$1" </dev/null; }
kv_version() { vault_root kv metadata get -format=json "secret/certs/$1" </dev/null |
  sed -n 's/.*"current_version": *\([0-9]*\).*/\1/p'; }
