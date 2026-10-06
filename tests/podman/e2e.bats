#!/usr/bin/env bats
# E2E: lego (kontti) -> Pebble (EAB, HTTP-01 nginxin kautta) -> Vault -> Linux-asiakkaan install-cert.sh.
# Lisäksi eristys (nginx ↛ Vault, ei reittiä ulos) ja salaisuuksien vuototarkistukset.
# Aja: tests/run-bats.sh tests/podman/e2e.bats   (KEEP_STACK=1 jättää ympäristön pystyyn)

# shellcheck disable=SC2153  # ROOT, T, EAB_* ym. tulevat helpers.bash:sta (load)
# shellcheck disable=SC2016  # sh -c -lausekkeet laajennetaan tarkoituksella vasta alikuoressa

bats_require_minimum_version 1.5.0

setup_file() {
  load helpers
  setup_dev_stack
}

teardown_file() {
  load helpers
  teardown_dev_stack
}

setup() {
  load helpers
}

@test "nginx on healthy ja ohjaa muun liikenteen HTTPS:ään" {
  run curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: web.acme.test' http://127.0.0.1:18080/foo
  [ "$status" -eq 0 ]
  [ "$output" = "301 https://web.acme.test/foo" ]
  wait_for 90 sh -c '[ "$(podman inspect acme-nginx --format "{{.State.Health.Status}}")" = healthy ]'
}

@test "Vault on alustettu, unsealed ja healthy" {
  run podman exec acme-vault vault status
  [ "$status" -eq 0 ]
  wait_for 90 sh -c '[ "$(podman inspect acme-vault --format "{{.State.Health.Status}}")" = healthy ]'
}

@test "acme-renew ilman EAB:tä ja ilman tiliä epäonnistuu hallitusti" {
  run run_lego
  [ "$status" -ne 0 ]
  run kv_field web not_after
  [ "$status" -ne 0 ]
}

@test "ensimmäinen ajo EAB:llä tilaa varmenteet HTTP-01:llä nginxin kautta" {
  run compose_eab --profile jobs run --rm -T lego
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vaultiin päivitetty: web"* ]]
  [[ "$output" == *"Vaultiin päivitetty: multi"* ]]
}

@test "Vaultissa on kaikki kentät ja domainit oikein" {
  for f in fullchain key bundle pfx_b64 pfx_password not_after domains; do
    run kv_field web "$f"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
  run kv_field multi domains
  echo "domains=$output"
  [ "$(tr ',' '\n' <<< "$output" | sort | paste -sd,)" = "a.acme.test,b.acme.test" ]
  # bundle = fullchain + avain, ja avain vastaa varmennetta
  kv_field web bundle > "$T/web-bundle.pem"
  diff <(openssl x509 -in "$T/web-bundle.pem" -noout -pubkey) <(openssl pkey -in "$T/web-bundle.pem" -pubout)
}

@test "PFX (modern) aukeaa salasanalla ja sisältää avaimen" {
  kv_field web pfx_b64 | base64 -d > "$T/web.pfx"
  PFXPW=$(kv_field web pfx_password) run openssl pkcs12 -in "$T/web.pfx" -passin env:PFXPW -nodes -info -noout
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AES-256-CBC"* ]]
  run openssl pkcs12 -in "$T/web.pfx" -passin pass:väärä -nodes -noout
  [ "$status" -ne 0 ]
}

@test "lego-data säilyttää tilin: ajo ilman EAB-salaisuuksia ei uusi turhaan" {
  before=$(kv_version web)
  run run_lego
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(kv_version web)" = "$before" ]
  run podman run --rm -v acme_lego-data:/d:ro --entrypoint cat "$LEGO_IMAGE_REF" /d/last-success
  [ "$status" -eq 0 ]
}

@test "uusinta (RENEW_DAYS > voimassaolo) vie uuden version Vaultiin" {
  before=$(kv_version web)
  old_serial=$(kv_field web fullchain | openssl x509 -noout -serial)
  run run_lego -e RENEW_DAYS=365
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(kv_version web)" -gt "$before" ]
  [ "$(kv_field web fullchain | openssl x509 -noout -serial)" != "$old_serial" ]
}

@test "PFX_COMPAT=legacy tuottaa 3DES/SHA1-PFX:n, joka aukeaa salasanalla" {
  run run_lego -e RENEW_DAYS=365 -e PFX_COMPAT=legacy
  [ "$status" -eq 0 ]
  kv_field web pfx_b64 | base64 -d > "$T/web-legacy.pfx"
  PFXPW=$(kv_field web pfx_password) run openssl pkcs12 -legacy -in "$T/web-legacy.pfx" -passin env:PFXPW -nodes -info -noout
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pbeWithSHA1And3-KeyTripleDES-CBC"* ]]
}

@test "Linux-asiakas: install-cert.sh asentaa Vaultin bundlen (Pebblen juuri luotettuna)" {
  mkdir -p "$T/client/staging" "$T/client/target"
  curl -sfk https://127.0.0.1:15000/roots/0 > "$T/client/dvv-ca.pem"
  kv_field web bundle > "$T/client/staging/web.pem"
  printf '%s\n' 'STAGING=/staging' 'TARGET=/target' 'DVV_CA=/dvv-ca.pem' 'MIN_VALID_SECONDS=604800' \
    'TEST_CMD=true' 'RELOAD_CMD=true' > "$T/client/cert-install.conf"
  run podman run --rm --network none \
    -v "$ROOT/linux/install-cert.sh:/usr/local/sbin/install-cert.sh:ro,z" \
    -v "$T/client/cert-install.conf:/etc/cert-install.conf:ro,z" \
    -v "$T/client/dvv-ca.pem:/dvv-ca.pem:ro,z" \
    -v "$T/client/staging:/staging:ro,z" -v "$T/client/target:/target:z" \
    "$CLIENT_IMAGE" bash /usr/local/sbin/install-cert.sh
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web: asennettu"* ]]
  cmp "$T/client/staging/web.pem" "$T/client/target/web.pem"
}

@test "Linux-asiakas hylkää bundlen, jonka avain ei vastaa varmennetta" {
  mkdir -p "$T/client2/staging" "$T/client2/target"
  cp "$T/client/dvv-ca.pem" "$T/client/cert-install.conf" "$T/client2/"
  { kv_field multi fullchain; kv_field web key; } > "$T/client2/staging/bad.pem"
  run podman run --rm --network none \
    -v "$ROOT/linux/install-cert.sh:/usr/local/sbin/install-cert.sh:ro,z" \
    -v "$T/client2/cert-install.conf:/etc/cert-install.conf:ro,z" \
    -v "$T/client2/dvv-ca.pem:/dvv-ca.pem:ro,z" \
    -v "$T/client2/staging:/staging:ro,z" -v "$T/client2/target:/target:z" \
    "$CLIENT_IMAGE" bash /usr/local/sbin/install-cert.sh
  echo "$output"
  [[ "$output" == *"avain ei vastaa varmennetta"* ]]
  [ ! -e "$T/client2/target/bad.pem" ]
}

@test "eristys: nginx-kontista Vault ei vastaa (nimi eikä IP)" {
  vip=$(podman inspect acme-vault --format '{{(index .NetworkSettings.Networks "acme_vault-net").IPAddress}}')
  [ -n "$vip" ]
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 https://vault:8200/v1/sys/health
  [ "$status" -ne 0 ]
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 "https://$vip:8200/v1/sys/health"
  [ "$status" -ne 0 ]
}

@test "eristys: lego-kontista Vault vastaa (vertailukohta)" {
  vip=$(podman inspect acme-vault --format '{{(index .NetworkSettings.Networks "acme_vault-net").IPAddress}}')
  run podman run --rm --network acme_vault-net --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$vip:8200/v1/sys/health"
  [ "$output" = "200" ]
}

@test "eristys: nginx- ja Vault-konteilla ei ole reittiä ulos" {
  for c in acme-nginx acme-vault; do
    run podman run --rm --network "container:$c" --entrypoint curl "$LEGO_IMAGE_REF" \
      -s --max-time 5 -o /dev/null http://1.1.1.1/
    [ "$status" -ne 0 ]
  done
}

@test "eristys: Vault julkaistu vain annettuun IP:hen" {
  run podman inspect acme-vault --format '{{range $p, $b := .HostConfig.PortBindings}}{{$p}}={{range $b}}{{.HostIP}}:{{.HostPort}} {{end}}{{end}}'
  [ "$output" = "8200/tcp=127.0.0.1:18200 " ]
}

@test "salaisuudet eivät näy podman inspectissä (nginx, vault, lego)" {
  token=$(podman run --rm --log-driver none --secret vault_token --entrypoint cat "$LEGO_IMAGE_REF" /run/secrets/vault_token)
  keyline=$(podman run --rm --log-driver none --secret vault_tls_key --entrypoint sed "$LEGO_IMAGE_REF" -n 2p /run/secrets/vault_tls_key)
  compose --profile jobs run -d --name acme-lego-inspect --entrypoint sleep lego 60 >/dev/null 3>&-
  for c in acme-nginx acme-vault acme-lego-inspect; do
    out=$(podman inspect "$c")
    [[ "$out" != *"$token"* ]]
    [[ "$out" != *"$keyline"* ]]
    [[ "$out" != *"$EAB_HMAC"* ]]
  done
  podman rm -f acme-lego-inspect >/dev/null
}

@test "salaisuudet eivät näy lokeissa (journald)" {
  token=$(podman run --rm --log-driver none --secret vault_token --entrypoint cat "$LEGO_IMAGE_REF" /run/secrets/vault_token)
  pfxpw=$(kv_field web pfx_password)
  root=$(cat "$T/root-token")
  logs=$(journalctl --user --since "$(cat "$T/started")" --no-pager -o cat 2>/dev/null || true)
  [ -n "$logs" ]
  if [[ "$logs" == *"$token"* ]]; then
    grep -F "$token" <<< "$logs" | sed "s/$token/<TOKEN>/g" | head -5
    false
  fi
  [[ "$logs" != *"$pfxpw"* ]]
  [[ "$logs" != *"$EAB_HMAC"* ]]
  [[ "$logs" != *"$root"* ]]
  [[ "$logs" != *"PRIVATE KEY"* ]]
}
