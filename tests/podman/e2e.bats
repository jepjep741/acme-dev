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

host_ip() { ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'; }

@test "eristys: nginx-kontista Vault ei vastaa (nimi, isännän IP eikä loopback)" {
  # Vain curlin verkkovirheet kelpaavat (6 nimi, 7 yhteys, 28 aikakatkaisu); 125 = podman-virhe
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 https://vault:18200/v1/sys/health
  [[ "$status" =~ ^(6|7|28)$ ]]
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 "https://$(host_ip):18200/v1/sys/health"
  [[ "$status" =~ ^(7|28)$ ]]
  # nginxin oma loopback ei ole isännän loopback
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -sk --max-time 5 https://127.0.0.1:18200/v1/sys/health
  [[ "$status" =~ ^(7|28)$ ]]
  # edge-verkossa ei ole oletusreittiä
  run podman exec acme-nginx ip route
  [[ "$output" != *default* ]]
}

@test "eristys: lego (isännän verkko) tavoittaa Vaultin (vertailukohta)" {
  run podman run --rm --log-driver none --network host -v "$T/config/tls/ca.pem:/ca.pem:ro,z" \
    --entrypoint curl "$LEGO_IMAGE_REF" \
    -s --cacert /ca.pem --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:18200/v1/sys/health
  [ "$output" = "200" ]
}

@test "eristys: nginx-kontilla ei ole reittiä ulos" {
  run podman run --rm --network container:acme-nginx --entrypoint curl "$LEGO_IMAGE_REF" \
    -s --max-time 5 -o /dev/null http://1.1.1.1/
  echo "curl $status"
  [[ "$status" =~ ^(7|28)$ ]]
}

@test "Vault ja lego isännän verkossa; Vault kuuntelee vain annetussa IP:ssä" {
  [ "$(podman inspect acme-vault --format '{{.HostConfig.NetworkMode}}')" = host ]
  run podman inspect acme-vault --format '{{len .HostConfig.PortBindings}}'
  [ "$output" = "0" ]
  run curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:18200/v1/sys/health
  [ "$output" = "200" ]
  run curl -sk --max-time 5 -o /dev/null "https://$(host_ip):18200/v1/sys/health"
  [ "$status" -eq 7 ]
}

@test "AppRole-CIDR-sidonta: Vault näkee asiakkaan todellisen IP:n" {
  vault_root auth list </dev/null | grep -q '^approle/'
  printf 'path "secret/data/certs/web" { capabilities = ["read"] }\n' | vault_root policy write cert-e2e - >/dev/null
  for r in e2e-ok:127.0.0.1/32 e2e-wrong:10.255.255.1/32; do
    vault_root write "auth/approle/role/${r%%:*}" token_policies=cert-e2e \
      secret_id_bound_cidrs="${r#*:}" token_bound_cidrs="${r#*:}" </dev/null >/dev/null
  done
  login() { # login <rooli> -> HTTP-koodi; secret_id kulkee stdinissä (ei komentorivillä)
    local rid sid
    rid=$(vault_root read -field=role_id "auth/approle/role/$1/role-id" </dev/null)
    sid=$(vault_root write -f -field=secret_id "auth/approle/role/$1/secret-id" </dev/null)
    printf '{"role_id":"%s","secret_id":"%s"}' "$rid" "$sid" |
      curl -s --cacert "$T/config/tls/ca.pem" -o /dev/null -w '%{http_code}' --data @- \
        https://127.0.0.1:18200/v1/auth/approle/login
  }
  [ "$(login e2e-ok)" = "200" ]
  [ "$(login e2e-wrong)" != "200" ]
  vault_root delete auth/approle/role/e2e-ok </dev/null >/dev/null
  vault_root delete auth/approle/role/e2e-wrong </dev/null >/dev/null
  vault_root policy delete cert-e2e </dev/null >/dev/null
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

@test "audit-loki: ei selväkielisiä tokeneita eikä PFX-salasanaa" {
  token=$(podman run --rm --log-driver none --secret vault_token --entrypoint cat "$LEGO_IMAGE_REF" /run/secrets/vault_token)
  pfxpw=$(kv_field web pfx_password)
  podman exec acme-vault test -s /vault/logs/audit.log
  run podman exec acme-vault grep -c -F -e "$token" -e "$pfxpw" /vault/logs/audit.log
  [ "$output" = "0" ]
}

@test "vault-audit-rotate.sh kiertää lokin, Vault jatkaa ja kirjoittaa uuteen lokiin" {
  run "$PODMAN_DIR/scripts/vault-audit-rotate.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kierretty audit.log."* ]]
  run podman exec acme-vault sh -c 'ls /vault/logs/audit.log.*.gz | wc -l'
  [ "$output" -ge 1 ]
  kv_field web not_after >/dev/null
  wait_for 10 podman exec acme-vault test -s /vault/logs/audit.log
  run podman exec acme-vault vault status
  [ "$status" -eq 0 ]
}

@test "egress-check.sh: nginx estetty, lego tavoittaa ACME:n; kehitysisännän avoin internet havaitaan" {
  ACME_ENV="$ENV_FILE" ACME_DIR="$PODMAN_DIR" ACME_COMPOSE_FILES=compose.dev.yaml \
    EGRESS_DENY_TARGETS="https://1.1.1.1/" run "$PODMAN_DIR/scripts/egress-check.sh" --skip-host
  echo "$output"
  # Kehitysisännällä ei ole nftables-rajausta: isännän verkossa olevien legon ja Vaultin pääsy
  # internetiin pitää havaita viaksi (tuotannossa nftables estää, ks. host.bats).
  [ "$status" -eq 1 ]
  [[ "$output" == *"[VIKA] lego -> https://1.1.1.1/: kohde tavoitettiin"* ]]
  [[ "$output" == *"[VIKA] acme-vault -> https://1.1.1.1/: kohde tavoitettiin"* ]]
  [[ "$output" == *"[OK]   acme-nginx -> https://1.1.1.1/ estetty"* ]]
  [[ "$output" == *"[OK]   acme-nginx -> https://127.0.0.1:14000/dir estetty"* ]]
  [[ "$output" != *"tarkistus ei ajautunut"* ]]
  # Pebblen varmenne ei ole järjestelmän luottama -> "tavoitettiin" (TLS), ei "ei vastaa"
  [[ "$output" == *"DVV tavoitettiin"* || "$output" == *"[OK]   DVV vastaa"* ]]
}

# ---------------------------------------------------------------- Vaihe 5: alustus ja ylläpito

admin_login() { # tulostaa ylläpitäjän tokenin (vain testi)
  # shellcheck source=podman/scripts/lib.sh
  source "$PODMAN_DIR/scripts/lib.sh"
  local t
  printf '%s\n%s\n%s\n' "$ADMIN_USER" "$ADMIN_PW" "$(fresh_totp)" | { vault_login_admin t && printf '%s' "$t"; }
}

@test "vault-init: avainosat ja root-token vain PGP-salattuina tiedostossa" {
  run python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print(sorted(d), d["unseal_shares"], d["unseal_threshold"])' "$T/keys.json"
  [[ "$output" == *"5 3"* ]]
  [[ "$output" != *"unseal_keys_b64'"* ]]
  root=$(cat "$T/root-token")
  run grep -c -F "$root" "$T/keys.json"
  [ "$output" = "0" ]
  [ "$(stat -c %a "$T/keys.json")" = "600" ]
}

@test "vault-init: uudelleenajo on idempotentti (init ohitetaan, configure uudelleen)" {
  run "$PODMAN_DIR/scripts/vault-init.sh" init --pgp-keys x --out /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"jo alustettu"* ]]
  VAULT_ADMIN_TOKEN_FILE="$T/root-token" run "$PODMAN_DIR/scripts/vault-init.sh" configure
  echo "$output"
  [ "$status" -eq 0 ]
  run vault_root read -field=max_versions secret/config </dev/null
  [ "$output" = "10" ]
  run vault_root policy list </dev/null
  for p in acme-writer acme-admin onboard-admin snapshot vault-admin; do [[ "$output" == *"$p"* ]]; done
  run vault_root list -format=json identity/mfa/method/totp </dev/null
  [ "$(python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' <<< "$output")" = "1" ]
}

@test "ylläpitäjä: kirjautuminen salasana + TOTP onnistuu, väärä TOTP ja salasana hylätään" {
  run bash -c "printf '%s\n%s\n%s\n' '$ADMIN_USER' '$ADMIN_PW' '$(fresh_totp)' | '$PODMAN_DIR/scripts/vault-init.sh' login-test"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault-admin"* && "$output" == *"onboard-admin"* ]]
  run bash -c "printf '%s\n%s\n%s\n' '$ADMIN_USER' '$ADMIN_PW' '000000' | '$PODMAN_DIR/scripts/vault-init.sh' login-test"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TOTP-tarkistus epäonnistui"* ]]
  run bash -c "printf '%s\n%s\n' '$ADMIN_USER' 'väärä' | '$PODMAN_DIR/scripts/vault-init.sh' login-test"
  [ "$status" -ne 0 ]
}

@test "ylläpitäjä ei pääse varmenteiden avaimiin eikä ilman MFA:ta saa tokenia" {
  tok=$(admin_login)
  [ -n "$tok" ]
  { printf '%s\n' "$tok"; } > "$T/admin-token"; chmod 600 "$T/admin-token"
  # shellcheck source=podman/scripts/lib.sh
  source "$PODMAN_DIR/scripts/lib.sh"
  run vault_tok "$tok" kv get -field=key secret/certs/web </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
  run vault_tok "$tok" kv metadata get secret/certs/web </dev/null
  [ "$status" -eq 0 ]
  # Ensimmäinen kirjautumisvaihe ei anna tokenia ilman TOTP:tä
  run bash -c "printf '%s' '$ADMIN_PW' | podman exec -i -e VAULT_TOKEN= acme-vault vault write -format=json auth/userpass/login/$ADMIN_USER password=-"
  [[ "$output" == *"mfa_request_id"* ]]
  [[ "$output" != *'"client_token": "hvs.'* ]]
}

@test "secrets.sh: vault-token idempotentti, --rotate vaihtaa ja mitätöi vanhan" {
  old=$(podman secret inspect --showsecret --format '{{.SecretData}}' vault_token)
  VAULT_ADMIN_TOKEN_FILE="$T/admin-token" run "$PODMAN_DIR/scripts/secrets.sh" vault-token
  [ "$status" -eq 0 ]; [[ "$output" == *"säilytetään"* ]]
  [ "$(podman secret inspect --showsecret --format '{{.SecretData}}' vault_token)" = "$old" ]
  VAULT_ADMIN_TOKEN_FILE="$T/admin-token" run "$PODMAN_DIR/scripts/secrets.sh" vault-token --rotate
  echo "$output"
  [ "$status" -eq 0 ]; [[ "$output" == *"vanha token mitätöity"* ]]
  new=$(podman secret inspect --showsecret --format '{{.SecretData}}' vault_token)
  [ "$new" != "$old" ]
  run bash -c "printf '%s\n' '$old' | podman exec -i acme-vault sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; vault token lookup'"
  [ "$status" -ne 0 ]
  # uusi token toimii legon hookissa
  run run_lego -e RENEW_DAYS=365
  [ "$status" -eq 0 ]
  run "$PODMAN_DIR/scripts/secrets.sh" list
  [[ "$output" == *vault_token* && "$output" != *"$new"* ]]
}

@test "vault-unseal: uudelleenkäynnistys sinetöi, väärä osa hylätään, 3 osaa avaa" {
  podman restart acme-vault >/dev/null
  wait_for 60 podman exec acme-vault sh -c 'vault status; [ $? -eq 2 ]'
  run "$PODMAN_DIR/scripts/healthcheck.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SINETÖITY"* ]]
  run bash -c "echo 'aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSBrZXk=' | '$PODMAN_DIR/scripts/vault-unseal.sh'"
  [ "$status" -ne 0 ]
  "$PODMAN_DIR/scripts/vault-unseal.sh" --reset
  { unseal_key 2; echo; unseal_key 3; echo; unseal_key 4; echo; } > "$T/keys3"
  run "$PODMAN_DIR/scripts/vault-unseal.sh" < "$T/keys3"
  rm -f "$T/keys3"
  echo "$output"
  [ "$status" -eq 0 ]
  run podman exec acme-vault vault status
  [ "$status" -eq 0 ]
}

@test "healthcheck.sh: avattu Vault, uusinta ja varmenteet OK" {
  run "$PODMAN_DIR/scripts/healthcheck.sh"
  echo "$output"
  [[ "$output" == *"Vault: avattu"* ]]
  [[ "$output" == *"uusinta: viimeisin onnistunut"* ]]
  [[ "$output" == *"varmenne web voimassa"* ]]
  [[ "$output" != *KRIITTINEN* ]]
}

@test "backup.sh: snapshot, salattu lego-data, config ja tarkistussummat" {
  run "$PODMAN_DIR/scripts/backup.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  b=$(find "$T/backup" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | tail -1)
  [ -s "$b/vault.snap" ]
  [ -s "$b/lego-data.tar.gpg" ]
  [ ! -e "$b/lego-data.tar" ]
  tar -tf "$b/config.tar" | grep -q 'certs.conf'
  [ "$(tar -tf "$b/config.tar" | grep -c private)" = "0" ]
  (cd "$b" && sha256sum -c --quiet SHA256SUMS)
  [ "$(stat -c %a "$b")" = "700" ]
  echo "$b" > "$T/last-backup"
}

@test "restore.sh verify havaitsee muutetun varmuuskopion" {
  b=$(cat "$T/last-backup"); cp -a "$b" "$T/tampered"
  printf 'x' >> "$T/tampered/config.tar"
  run "$PODMAN_DIR/scripts/restore.sh" verify "$T/tampered"
  [ "$status" -ne 0 ]
  [[ "$output" == *"eivät täsmää"* ]]
  run "$PODMAN_DIR/scripts/restore.sh" vault "$T/tampered" --yes
  [ "$status" -ne 0 ]
}

@test "palautustesti: tyhjä Vault + snapshot + alkuperäiset avainosat -> varmenteet palautuvat" {
  b=$(cat "$T/last-backup")
  want=$(kv_field web not_after)
  compose stop vault >/dev/null 2>&1 3>&-
  podman rm -f acme-vault >/dev/null
  podman volume rm -f acme_vault-data >/dev/null
  compose up -d vault >/dev/null 2>&1 3>&-
  wait_for 60 podman exec acme-vault sh -c 'vault status; [ $? -eq 2 ]'
  run podman exec acme-vault sh -c 'vault status -format=json | grep "\"initialized\": false"'
  [ "$status" -eq 0 ]
  run "$PODMAN_DIR/scripts/restore.sh" vault "$b" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  { unseal_key 0; echo; unseal_key 1; echo; unseal_key 2; echo; } | "$PODMAN_DIR/scripts/vault-unseal.sh"
  [ "$(kv_field web not_after)" = "$want" ]
  # palvelutoken on palautunut ja toimii
  run run_lego -e RENEW_DAYS=365
  [ "$status" -eq 0 ]
}

@test "palautustesti: lego-data GPG-salatusta varmuuskopiosta" {
  b=$(cat "$T/last-backup")
  podman volume rm -f acme_lego-data >/dev/null
  run "$PODMAN_DIR/scripts/restore.sh" lego-data "$b" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  before=$(kv_version web)
  run run_lego
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"EAB"* ]]
  [ "$(kv_version web)" = "$before" ]
}

# ---------------------------------------------------------------- Vaihe 6: liittäminen

onboard() { VAULT_ADMIN_TOKEN_FILE="$T/admin-token" "$PODMAN_DIR/scripts/onboard-server.sh" "$@"; }

# Vault-komento "palvelimelta" (isännän verkko, lähde 127.0.0.1): token stdinin 1. rivinä
agent_vault() {
  podman run --rm -i --log-driver none --network host -v "$T/config/tls/ca.pem:/ca.pem:ro,z" \
    -e VAULT_ADDR=https://127.0.0.1:18200 -e VAULT_CACERT=/ca.pem --entrypoint sh "$LEGO_IMAGE_REF" \
    -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"
}

@test "onboard-server.sh add: rooli, CIDR-sidonta ja kääre; agentti hakee bundlen ja install-cert.sh asentaa" {
  run onboard add e2e-srv 127.0.0.1 web
  echo "$output"
  [ "$status" -eq 0 ]
  rid=$(sed -n 's/^role_id: *//p' <<< "$output")
  wrapped=$(sed -n 's/^wrapped secret_id: *\([^ ]*\).*/\1/p' <<< "$output")
  [[ "$rid" =~ ^[0-9a-f-]{36}$ ]]
  [ -n "$wrapped" ]
  # Kääreen purku palvelimella (kertakäyttöinen)
  sid=$(printf '%s\n' "$wrapped" | agent_vault unwrap -field=secret_id)
  [ -n "$sid" ]
  run bash -c "printf '%s\n' '$wrapped' | podman run --rm -i --log-driver none --network host -v '$T/config/tls/ca.pem:/ca.pem:ro,z' -e VAULT_ADDR=https://127.0.0.1:18200 -e VAULT_CACERT=/ca.pem --entrypoint sh '$LEGO_IMAGE_REF' -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; vault unwrap -field=secret_id'"
  [ "$status" -ne 0 ]
  # Vault Agent (linux/agent.hcl:n mukainen, kertaajo) renderöi bundlen staging-hakemistoon
  mkdir -p "$T/agent/staging"; chmod 777 "$T/agent/staging"
  printf '%s' "$rid" > "$T/agent/role_id"; printf '%s' "$sid" > "$T/agent/secret_id"; chmod 644 "$T/agent/role_id" "$T/agent/secret_id"
  cat > "$T/agent/agent.hcl" <<'HCL'
vault {
  address = "https://127.0.0.1:18200"
  ca_cert = "/ca.pem"
}
auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/agent/role_id"
      secret_id_file_path                 = "/agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}
template {
  contents             = "{{ with secret \"secret/data/certs/web\" }}{{ .Data.data.bundle }}{{ end }}"
  destination          = "/agent/staging/web.pem"
  perms                = "0640"
  error_on_missing_key = true
}
HCL
  # Agentti ajetaan kuten tuotannossa (jatkuva prosessi); odotetaan renderöintiä ja pysäytetään.
  podman run -d --name acme-e2e-agent --log-driver none --network host -v "$T/config/tls/ca.pem:/ca.pem:ro,z" \
    -e VAULT_CACERT=/ca.pem -v "$T/agent:/agent:z" --entrypoint vault "$LEGO_IMAGE_REF" agent -config=/agent/agent.hcl >/dev/null 3>&-
  wait_for 60 test -s "$T/agent/staging/web.pem" || { podman logs acme-e2e-agent; false; }
  podman rm -f acme-e2e-agent >/dev/null
  # Tiedosto on agentin (kontin uid) omistama 0640: luetaan käyttäjänimiavaruudessa
  cmp <(kv_field web bundle) <(podman unshare cat "$T/agent/staging/web.pem")
  # install-cert.sh asentaa agentin renderöimän bundlen (sama ketju kuin Linux-palvelimella)
  mkdir -p "$T/agent/target"
  run podman run --rm --network none \
    -v "$ROOT/linux/install-cert.sh:/usr/local/sbin/install-cert.sh:ro,z" \
    -v "$T/client/cert-install.conf:/etc/cert-install.conf:ro,z" -v "$T/client/dvv-ca.pem:/dvv-ca.pem:ro,z" \
    -v "$T/agent/staging:/staging:ro,z" -v "$T/agent/target:/target:z" \
    "$CLIENT_IMAGE" bash /usr/local/sbin/install-cert.sh
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web: asennettu"* ]]
  # Pääsy vain omaan varmenteeseen
  tok=$(printf '{"role_id":"%s","secret_id":"%s"}' "$rid" "$sid" | curl -s --cacert "$T/config/tls/ca.pem" --data @- \
    https://127.0.0.1:18200/v1/auth/approle/login | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])')
  run bash -c "printf '%s\n' '$tok' | podman run --rm -i --log-driver none --network host -v '$T/config/tls/ca.pem:/ca.pem:ro,z' -e VAULT_ADDR=https://127.0.0.1:18200 -e VAULT_CACERT=/ca.pem --entrypoint sh '$LEGO_IMAGE_REF' -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; vault kv get -field=domains secret/certs/multi'"
  [ "$status" -ne 0 ]
}

@test "onboard-server.sh: rooli väärällä IP:llä ei kirjaudu" {
  run onboard add e2e-wrongip 10.9.9.9 web
  [ "$status" -eq 0 ]
  wrapped=$(sed -n 's/^wrapped secret_id: *\([^ ]*\).*/\1/p' <<< "$output")
  sid=$(printf '%s\n' "$wrapped" | agent_vault unwrap -field=secret_id)
  rid=$(sed -n 's/^role_id: *//p' <<< "$output")
  code=$(printf '{"role_id":"%s","secret_id":"%s"}' "$rid" "$sid" | curl -s --cacert "$T/config/tls/ca.pem" \
    -o /dev/null -w '%{http_code}' --data @- https://127.0.0.1:18200/v1/auth/approle/login)
  [ "$code" != "200" ]
  onboard remove e2e-wrongip
}

@test "onboard-server.sh rotate + destroy-old jättää vain uusimman secret_id:n; list näyttää palvelimen" {
  run onboard rotate e2e-srv
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"destroy-old e2e-srv"* ]]
  run vault_root list -format=json auth/approle/role/e2e-srv/secret-id </dev/null
  [ "$(python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' <<< "$output")" = "2" ]
  run onboard destroy-old e2e-srv
  [ "$status" -eq 0 ]
  run vault_root list -format=json auth/approle/role/e2e-srv/secret-id </dev/null
  [ "$(python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' <<< "$output")" = "1" ]
  run onboard list
  echo "$output"
  [[ "$output" == *"e2e-srv"*"127.0.0.1/32"*"web"* ]]
}

@test "onboard-server.sh csv: parametritiedostot ilman salaisuuksia, Install-WindowsAgent-yhteensopivat" {
  printf '%s\n' '# palvelin;ip;varmenne=host:port|host:port' \
    'e2e-win1;10.1.2.31;web=web.acme.test:443' \
    'e2e-win2;10.1.2.32;web=web.acme.test:443;multi=a.acme.test:443|b.acme.test:8443' > "$T/servers.csv"
  run onboard csv "$T/servers.csv" --out "$T/params" --vault-exe-sha256 "$VAULT_WINDOWS_SHA256"
  echo "$output"
  [ "$status" -eq 0 ]
  run python3 -c 'import sys,json
d=json.load(open(sys.argv[1]))
assert d["Server"]=="e2e-win2" and d["VaultAddress"]=="https://vault.test:8200"
assert d["Certificates"]=={"web":["web.acme.test:443"],"multi":["a.acme.test:443","b.acme.test:8443"]}, d["Certificates"]
assert len(d["RoleId"])==36 and d["RevocationMode"]=="NoCheck"
for k in d: assert "token" not in k.lower() and "secret" not in k.lower(), k
print("ok")' "$T/params/e2e-win2.json"
  echo "$output"
  [ "$output" = "ok" ]
  run grep -rqE 'hvs\.|s\.[A-Za-z0-9]{24}' "$T/params"
  [ "$status" -eq 1 ]
  run onboard csv <(printf 'huono;999.1.1.1;web=x:1\n') --out "$T/params-bad"
  [ "$status" -ne 0 ]
  onboard remove e2e-win1; onboard remove e2e-win2
}

@test "onboard-server.sh remove: secret_id:t hävitetty, rooli ja policy poistettu" {
  run onboard remove e2e-srv
  echo "$output"
  [ "$status" -eq 0 ]
  run vault_root read auth/approle/role/e2e-srv </dev/null
  [ "$status" -ne 0 ]
  run vault_root policy read cert-e2e-srv </dev/null
  [ "$status" -ne 0 ]
}

@test "revoke-root: root-token mitätöidään, ylläpitäjä toimii edelleen" {
  run "$PODMAN_DIR/scripts/vault-init.sh" revoke-root </dev/null
  [ "$status" -ne 0 ]   # ilman tokenia ja ilman TTY:tä kirjautuminen epäonnistuu
  VAULT_ADMIN_TOKEN_FILE="$T/admin-token" run "$PODMAN_DIR/scripts/vault-init.sh" revoke-root
  [ "$status" -ne 0 ]; [[ "$output" == *"ei ole root-token"* ]]
  VAULT_ADMIN_TOKEN_FILE="$T/root-token" run "$PODMAN_DIR/scripts/vault-init.sh" revoke-root
  echo "$output"
  [ "$status" -eq 0 ]
  run vault_root token lookup </dev/null
  [ "$status" -ne 0 ]
  tok=$(admin_login); [ -n "$tok" ]
}
