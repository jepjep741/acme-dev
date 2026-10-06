#!/usr/bin/env bats
# Julkaisupaketti: allekirjoituksen ja summien tarkistus (myös peukaloinnit) ja offline-asennus
# RHEL 9 -yhteensopivassa kontissa ILMAN VERKKOA (--network none, systemd/journald, rootful podman).
#
# Paketti: RELEASE_TEST_DIR + RELEASE_TEST_PUBKEY (valmiiksi rakennettu), muuten rakennetaan
# testiavaimella (--skip-scan). [VERKKO: vain rakennus]

# shellcheck disable=SC2153  # ROOT ym. tulevat helpers.bash:sta (load)
# shellcheck disable=SC2016  # kontissa ajettavat skriptit ovat tarkoituksella yksinkertaisissa lainausmerkeissä

bats_require_minimum_version 1.5.0

setup_file() {
  load helpers
  export RT="$BATS_FILE_TMPDIR/rel"
  mkdir -p "$RT"
  if [[ -n "${RELEASE_TEST_DIR:-}" ]]; then
    cp -a "$RELEASE_TEST_DIR" "$RT/pkg"
    cp "$RELEASE_TEST_PUBKEY" "$RT/key.asc"
  else
    export GNUPGHOME="$RT/gnupg"; install -d -m 700 "$GNUPGHOME"
    gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
      --quick-gen-key "acme release test <rt@example.org>" ed25519 sign 1d 2>/dev/null
    fpr=$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
    "$PODMAN_DIR/scripts/build-release.sh" --version 0.0.1-test --gpg-key "$fpr" --out "$RT/out" --skip-scan >/dev/null 2>&1
    cp -a "$RT/out/0.0.1-test" "$RT/pkg"
    cp "$RT/out/release-signing-key-0.0.1-test.asc" "$RT/key.asc"
  fi
  # Väärä avain peukalointitesteihin
  export GNUPGHOME="$RT/gnupg-other"; install -d -m 700 "$GNUPGHOME"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "hyokkaaja <x@example.org>" ed25519 sign 1d 2>/dev/null
  gpg --batch --armor --export x@example.org > "$RT/other.asc"
}

teardown_file() {
  podman rm -f acme-offline >/dev/null 2>&1 || true
}

setup() {
  load helpers
  IMPORT="$RT/pkg/podman/scripts/import-release.sh"
}

copy_pkg() { rm -rf "$RT/t"; cp -a "$RT/pkg" "$RT/t"; }

@test "paketti: allekirjoitus ja summat kelpaavat (--verify-only)" {
  run "$IMPORT" "$RT/pkg" --pubkey "$RT/key.asc" --verify-only
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Allekirjoitus OK"* && "$output" == *"Tarkistussummat OK"* ]]
}

@test "paketti: sisältö (imaget digestillä, vault.exe, ei kehitys- eikä testitiedostoja)" {
  [ -s "$RT/pkg/images/nginx.oci.tar" ] && [ -s "$RT/pkg/images/vault.oci.tar" ] && [ -s "$RT/pkg/images/lego.oci.tar" ]
  run awk -F'\t' '$2 !~ /@sha256:[0-9a-f]{64}$/' "$RT/pkg/IMAGES.txt"
  [ -z "$output" ]
  [ "$(wc -l < "$RT/pkg/IMAGES.txt")" -eq 3 ]
  grep -qE '^LEGO_IMAGE=localhost/acme-lego@sha256:[0-9a-f]{64}$' "$RT/pkg/podman/.env.example"
  [ "$(head -c2 "$RT/pkg/bin/vault.exe")" = "MZ" ]
  [ ! -e "$RT/pkg/podman/compose.dev.yaml" ]
  [ ! -e "$RT/pkg/tests" ]
  [ ! -e "$RT/pkg/podman/.env" ]
  [ -s "$RT/pkg/DEPENDENCIES.md" ] && [ -s "$RT/pkg/CHANGELOG.md" ] && [ -s "$RT/pkg/scan/SUMMARY.txt" ]
  run grep -rlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$RT/pkg/podman" "$RT/pkg/windows" "$RT/pkg/linux" "$RT/pkg/docs"
  [ -z "$output" ]
}

@test "peukalointi: muutettu tiedosto hylätään ennen latausta" {
  copy_pkg; printf '# muutos\n' >> "$RT/t/podman/compose.yaml"
  run "$IMPORT" "$RT/t" --pubkey "$RT/key.asc" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"tarkistussummat eivät täsmää"* ]]
}

@test "peukalointi: listaamaton lisätiedosto hylätään" {
  copy_pkg; printf 'x' > "$RT/t/images/extra.oci.tar"
  run "$IMPORT" "$RT/t" --pubkey "$RT/key.asc" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"ei kata"*"images/extra.oci.tar"* ]]
}

@test "peukalointi: uudelleenlasketut summat ilman avainta -> allekirjoitus ei kelpaa" {
  copy_pkg; printf '# muutos\n' >> "$RT/t/podman/compose.yaml"
  (cd "$RT/t" && find . -type f ! -name 'SHA256SUMS*' -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
  run "$IMPORT" "$RT/t" --pubkey "$RT/key.asc" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"allekirjoitus EI kelpaa"* ]]
}

@test "peukalointi: väärä luotettu avain tai puuttuva allekirjoitus hylätään" {
  run "$IMPORT" "$RT/pkg" --pubkey "$RT/other.asc" --verify-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"allekirjoitus EI kelpaa"* ]]
  copy_pkg; rm "$RT/t/SHA256SUMS.asc"
  run "$IMPORT" "$RT/t" --pubkey "$RT/key.asc" --verify-only
  [ "$status" -ne 0 ]
}

@test "offline-asennus (--network none): rootless acmesvc, tuonti, imaget digestillä, nginx ja Vault käynnistyvät" {
  podman rm -f acme-offline >/dev/null 2>&1 || true
  podman run -d --name acme-offline --privileged --network none --systemd=always --log-driver none \
    -v "$RT/pkg:/media/release:ro,z" -v "$RT/key.asc:/media/key.asc:ro,z" \
    localhost/acme-test-rhel-host:1 /sbin/init >/dev/null 3>&-
  # konttina "degraded" on tavallinen; riittää, että käynnistys on valmis
  wait_for 90 sh -c 'podman exec acme-offline systemctl is-system-running 2>/dev/null | grep -qE "^(running|degraded)$"'
  run timeout 900 podman exec acme-offline bash -c '
    set -euo pipefail
    ls /sys/class/net | grep -vx lo && { echo "VERKKO LÖYTYI"; exit 1; } || true
    # Testiympäristön erot oikeaan RHEL-isäntään (ei koske tuotettavaa ratkaisua):
    #  - sisäinen DNS (ei tavoitettavissa) kuten ilmaraossa; rootless-verkko vaatii resolv.confin
    #  - sisäkkäinen käyttäjänimiavaruus: pieni subuid-alue, newuidmapin setuid palautetaan
    printf "nameserver 192.0.2.53\n" > /etc/resolv.conf
    chmod u+s /usr/bin/newuidmap /usr/bin/newgidmap
    useradd --system --create-home --home-dir /var/lib/acmesvc --shell /usr/sbin/nologin acmesvc
    usermod --add-subuids 10000-59999 --add-subgids 10000-59999 acmesvc
    loginctl enable-linger acmesvc
    uid=$(id -u acmesvc); for i in $(seq 30); do [ -d /run/user/$uid ] && break; sleep 1; done
    install -d -o acmesvc -g acmesvc /var/lib/acmesvc/.config /var/lib/acmesvc/.config/containers
    printf "[storage]\ndriver = \"vfs\"\n" > /var/lib/acmesvc/.config/containers/storage.conf
    chown acmesvc: /var/lib/acmesvc/.config/containers/storage.conf
    A=(runuser -u acmesvc -- env XDG_RUNTIME_DIR=/run/user/$uid ACME_ENV=/etc/acme-podman/.env)
    cd /
    cp -a /media/release /var/tmp/rel
    /var/tmp/rel/podman/scripts/import-release.sh /var/tmp/rel --pubkey /media/key.asc --user acmesvc
    test -L /opt/acme/current
    ls -A /opt/acme/releases | grep -q "^\.import" && { echo "IMPORT-JÄÄNNE"; exit 1; } || true
    install -d -m 0755 -o root -g acmesvc /etc/acme-podman
    install -d -m 0755 -o acmesvc -g acmesvc /etc/acme-podman/tls
    sed -e "s|^VAULT_BIND_IP=.*|VAULT_BIND_IP=127.0.0.1|" -e "s|^VAULT_API_ADDR=.*|VAULT_API_ADDR=https://vault.test:8200|" \
        -e "s|^LEGO_SERVER=.*|LEGO_SERVER=https://acme.invalid/dir|" -e "s|^LEGO_EMAIL=.*|LEGO_EMAIL=x@example.org|" \
        -e "s|^ACME_CONF_DIR=.*|ACME_CONF_DIR=/etc/acme-podman|" -e "s|^BACKUP_DIR=.*|BACKUP_DIR=/var/tmp|" \
        /opt/acme/current/podman/.env.example > /etc/acme-podman/.env
    chgrp acmesvc /etc/acme-podman/.env; chmod 0640 /etc/acme-podman/.env
    cp /opt/acme/current/podman/config/certs.conf /etc/acme-podman/
    cd /opt/acme/current/podman
    "${A[@]}" scripts/tls-init.sh generate --dir /etc/acme-podman/tls --dns vault.test --ip 127.0.0.1 >/dev/null 2>&1
    printf placeholder | "${A[@]}" podman secret create vault_token - >/dev/null
    timeout 300 "${A[@]}" scripts/acme-compose.sh up -d >/dev/null 2>&1
    for i in $(seq 60); do curl -sf --max-time 3 http://127.0.0.1:8080/healthz >/dev/null && break; sleep 1; done
    echo "nginx: $(curl -s --max-time 3 http://127.0.0.1:8080/healthz)"
    # vault status: 2 = sinetöity (ei virhe); set -e ei saa katkaista
    for i in $(seq 60); do rc=0; "${A[@]}" podman exec acme-vault vault status >/dev/null 2>&1 || rc=$?; [ $rc -eq 2 ] && break; sleep 1; done
    { "${A[@]}" podman exec acme-vault vault status -format=json || true; } | grep -E "\"(initialized|sealed)\""
    img=$(sed -n "s/^LEGO_IMAGE=//p" /etc/acme-podman/.env)
    "${A[@]}" podman run --rm --network none --entrypoint lego "$img" --version
    "${A[@]}" podman run --rm --network container:acme-nginx --entrypoint getent "$img" hosts acme-vault >/dev/null 2>&1 \
      && echo "nginx: DNS TOIMII" || echo "nginx: ei nimipalvelua"
    timeout 120 "${A[@]}" scripts/smoke-test.sh || true
  '
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Allekirjoitus OK"* ]]
  [[ "$output" == *"nginx: ok"* ]]
  [[ "$output" == *'"initialized": false'* && "$output" == *'"sealed": true'* ]]
  [[ "$output" == *"lego version 5.5.2"* ]]
  [[ "$output" != *"VERKKO LÖYTYI"* && "$output" != *"IMPORT-JÄÄNNE"* ]]
  [[ "$output" == *"nginx: ei nimipalvelua"* ]]
  [[ "$output" == *"[OK]   acme-nginx käynnissä"* && "$output" == *"[OK]   acme-vault käynnissä"* ]]
  [[ "$output" == *"[OK]   haastepolku vastaa"* && "$output" == *"[OK]   muu liikenne -> 301 https"* ]]
  [[ "$output" == *"[VIKA] Vault alustamaton"* ]]
}
