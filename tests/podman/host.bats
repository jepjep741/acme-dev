#!/usr/bin/env bats
# install-host.sh, nftables-egress ja systemd-yksiköt RHEL 9 -yhteensopivassa kontissa.
# Ei vaadi dev-stackia. Vaatii verkon (egress-toiminnallinen testi). [VERKKO]
# Ei testaa (vaatii oikean RHEL-isännän): firewalld, linger, SELinux-kontekstit, systemctl --user.

# shellcheck disable=SC2153  # ROOT ym. tulevat helpers.bash:sta (load)
# shellcheck disable=SC2016  # kontissa ajettavat skriptit ovat tarkoituksella yksinkertaisissa lainausmerkeissä

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  HOST_IMAGE=localhost/acme-test-rhel-host:1
  # Repo julkaisun paikalle kuten tuotannossa (/opt/acme/current -> releases/<versio>)
  HOST_OPTS=(--rm --log-driver none --security-opt label=disable -v "$ROOT:/opt/acme/releases/test:ro")
  HOST_RUN=(podman run "${HOST_OPTS[@]}" "$HOST_IMAGE")
  HOST_RUN_NET=(podman run "${HOST_OPTS[@]}" --cap-add NET_ADMIN "$HOST_IMAGE")
}

in_host() { # in_host <bash-skripti>  (kontissa rootina)
  "${HOST_RUN[@]}" bash -c "set -euo pipefail; ln -s /opt/acme/releases/test /opt/acme/current; $1"
}

@test "install-host.sh --help ja tuntematon komento" {
  run "$PODMAN_DIR/scripts/install-host.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"enable-services"* ]]
  run "$PODMAN_DIR/scripts/install-host.sh" bogus
  [ "$status" -eq 2 ]
}

@test "install-host.sh hylkää virheelliset syötteet" {
  run "$PODMAN_DIR/scripts/install-host.sh" print-nft --uid 990 --subuid-range 100000-165535 --egress-allow 300.1.1.1:443
  [ "$status" -ne 0 ]; [[ "$output" == *"virheellinen osoite"* ]]
  run "$PODMAN_DIR/scripts/install-host.sh" print-nft --uid 990 --subuid-range 100000-165535 --egress-allow 192.0.2.1:99999
  [ "$status" -ne 0 ]; [[ "$output" == *"virheellinen portti"* ]]
  run "$PODMAN_DIR/scripts/install-host.sh" print-nft --uid 990 --subuid-range 100000-165535 --dns 'x;rm'
  [ "$status" -ne 0 ]
  run "$PODMAN_DIR/scripts/install-host.sh" print-nft --uid 990 --subuid-range 9-1
  [ "$status" -ne 0 ]
  run "$PODMAN_DIR/scripts/install-host.sh" print-nft --uid 'a b'
  [ "$status" -ne 0 ]
}

@test "install --dry-run ei muuta mitään" {
  run in_host '/opt/acme/current/podman/scripts/install-host.sh install --server-cidrs 10.1.0.0/16 --vault-ip 10.0.0.10 \
      --egress-allow 192.0.2.10:443 --dns 10.0.0.53 --dry-run
    ! id acmesvc
    [ ! -e /etc/acme-podman ]
    echo DRYRUN-OK'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] useradd"* ]]
  [[ "$output" == *"[dry-run] firewall-cmd --permanent --zone=public --add-rich-rule="*"10.1.0.0/16"*"port=8200"* ]]
  [[ "$output" == *"DRYRUN-OK"* ]]
}

@test "install on idempotentti (kaksi ajoa): käyttäjä, subuid, hakemistot, yksiköt, .env säilyy" {
  run in_host '
    I=/opt/acme/current/podman/scripts/install-host.sh
    A=(install --server-cidrs 10.1.0.0/16 --vault-ip 10.0.0.10 --skip-packages --skip-firewall --skip-egress --skip-linger)
    $I "${A[@]}" >/dev/null 2>&1
    echo "VAULT_BIND_IP=10.0.0.10" >> /etc/acme-podman/.env
    $I "${A[@]}" >/dev/null 2>&1
    getent passwd acmesvc | cut -d: -f6,7
    grep -c "^acmesvc:" /etc/subuid /etc/subgid
    stat -c "%U:%G %a %n" /etc/acme-podman /etc/acme-podman/.env /etc/acme-podman/tls /srv/acme-backup /var/lib/acmesvc
    grep -c "^VAULT_BIND_IP=10.0.0.10" /etc/acme-podman/.env
    ls /var/lib/acmesvc/.config/systemd/user | sort | tr "\n" " "'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/var/lib/acmesvc:/usr/sbin/nologin"* ]]
  [[ "$output" == *"/etc/subuid:1"* ]]
  [[ "$output" == *"/etc/subgid:1"* ]]
  [[ "$output" == *"root:acmesvc 640 /etc/acme-podman/.env"* ]]
  [[ "$output" == *"acmesvc:acmesvc 700 /srv/acme-backup"* ]]
  [[ "$output" == *"acmesvc:acmesvc 700 /var/lib/acmesvc"* ]]
  [[ "$output" == *"acme-renew.timer acme-stack.service"* ]]
  [[ "$output" != *"acme-egress-nft.service"* ]]
  # käyttäjän lisäämä rivi säilyi (ei ylikirjoitusta)
  [[ "$(grep -c '^1$' <<< "$output")" -ge 1 ]]
}

@test "install --skip-packages keskeyttää, jos paketti puuttuu" {
  run in_host 'rpm -e --nodeps podman-compose >/dev/null
    /opt/acme/current/podman/scripts/install-host.sh install --server-cidrs 10.1.0.0/16 --vault-ip 10.0.0.10 --skip-packages'
  [ "$status" -ne 0 ]
  [[ "$output" == *"puuttuvat paketit: podman-compose"* ]]
}

@test "nftables-säännöt kelpaavat (nft -c), myös tyhjillä listoilla" {
  run "${HOST_RUN_NET[@]}" bash -c '
    S=/opt/acme/releases/test/podman/scripts/install-host.sh
    $S print-nft --uid 990 --subuid-range 100000-165535 --egress-allow 192.0.2.10:443,198.51.100.0/24:80 --dns 10.0.0.53 > /tmp/a.nft
    $S print-nft --uid 990 --subuid-range 100000-165535 > /tmp/b.nft
    nft -c -f /tmp/a.nft && nft -c -f /tmp/b.nft && echo NFT-OK'
  echo "$output"
  [[ "$output" == *"NFT-OK"* ]]
}

@test "nftables rajaa palvelukäyttäjän ja sen subuid-alueen (isännän verkon kontit); root ei rajattu" {
  run "${HOST_RUN_NET[@]}" bash -c '
    useradd --system acmesvc
    # Testikontti (itse rootless) kattaa vain 65536 uid:tä, joten subuid-alue on tässä 30000-45535;
    # tuotannossa tyypillisesti 100000-165535. Mekanismi on sama.
    usermod --add-subuids 30000-45535 --add-subgids 30000-45535 acmesvc
    # Isännän verkossa ajetun kontin prosessi näkyy isännällä subuid-käyttäjänä (Vault uid 100 -> alku+99)
    useradd -M -u 30099 kontti-vault
    useradd -M -u 50000 alueen-ulkopuolella
    ns=$(awk "/^nameserver/{print \$2; exit}" /etc/resolv.conf)
    /opt/acme/releases/test/podman/scripts/install-host.sh print-nft --user acmesvc \
      --egress-allow 1.1.1.1:443 --dns "$ns" > /tmp/e.nft
    grep -q "meta skuid { $(id -u acmesvc), 30000-45535 }" /tmp/e.nft && echo "skuid-alue OK"
    nft -f /tmp/e.nft
    c() { rc=0; "$@" curl -s -o /dev/null --max-time 8 "$U" || rc=$?; echo "$rc"; }
    U=https://1.1.1.1/; echo "svc-allowed=$(c runuser -u acmesvc --)"
    U=https://8.8.8.8/; echo "svc-denied=$(c runuser -u acmesvc --)"
    U=https://1.1.1.1/; echo "subuid-allowed=$(c runuser -u kontti-vault --)"
    U=https://8.8.8.8/; echo "subuid-denied=$(c runuser -u kontti-vault --)"
    U=https://8.8.8.8/; echo "outside=$(c runuser -u alueen-ulkopuolella --)"
    U=https://8.8.8.8/; echo "root=$(c env)"'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skuid-alue OK"* ]]
  [[ "$output" == *"svc-allowed=0"* ]]
  [[ "$output" == *"svc-denied=7"* ]]
  [[ "$output" == *"subuid-allowed=0"* ]]
  [[ "$output" == *"subuid-denied=7"* ]]
  [[ "$output" == *"outside=0"* ]]
  [[ "$output" == *"root=0"* ]]
}

@test "systemd-yksiköt: syntaksi ja polut (systemd-analyze verify)" {
  run in_host '
    for u in /opt/acme/current/podman/systemd/*.service /opt/acme/current/podman/systemd/*.timer; do
      systemd-analyze verify "$u" 2>&1 | grep -v -e "Failed to put bus name" -e "not supported in containers" || true
    done; echo VERIFY-DONE'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERIFY-DONE"* ]]
  [[ "$output" != *"Unknown"* ]]
  [[ "$output" != *"is not executable"* ]]
  [[ "$output" != *"Failed to"*"load"* ]]
  [[ "$output" != *"Missing"* ]]
}

@test "acme-compose.sh: --help ja puuttuva .env antaa selvän virheen" {
  run "$PODMAN_DIR/scripts/acme-compose.sh" --help
  [ "$status" -eq 0 ]
  ACME_ENV=/nonexistent run "$PODMAN_DIR/scripts/acme-compose.sh" ps
  [ "$status" -eq 1 ]
  [[ "$output" == *"/nonexistent puuttuu"* ]]
}
