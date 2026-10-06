#!/usr/bin/env bash
# Valmistelee testiympäristön (imaget, bats) ja ajaa bats-testit isännällä.
# Vain rakennusympäristö: hakee verkosta kiinnitetyt imaget ja bats-coren. [VERKKO]
#   tests/run-bats.sh [--prepare-only] [bats-tiedostot...]   (oletus: tests/podman)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=podman/versions.env
source "$ROOT/podman/versions.env"

BATS_VERSION=1.13.0
BATS_SHA256=a85e12b8828271a152b338ca8109aa23493b57950987c8e6dff97ba492772ff3
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/acme-tests

usage() { echo "Käyttö: $0 [--prepare-only] [bats-tiedostot...]"; }

ensure_bats() {
  local dir="$CACHE/bats-core-$BATS_VERSION"
  if [[ ! -x "$dir/bin/bats" ]]; then
    mkdir -p "$CACHE"
    curl -fsSLo "$CACHE/bats.tar.gz" "https://github.com/bats-core/bats-core/archive/refs/tags/v$BATS_VERSION.tar.gz"
    echo "$BATS_SHA256  $CACHE/bats.tar.gz" | sha256sum -c - >/dev/null
    tar -xzf "$CACHE/bats.tar.gz" -C "$CACHE"
  fi
  BATS="$dir/bin/bats"
}

ensure_image() { podman image exists "$1" || podman pull -q "$1" >/dev/null; }

prepare() {
  ensure_bats
  ensure_image "$PEBBLE_IMAGE"
  ensure_image "$CHALLTESTSRV_IMAGE"
  ensure_image docker.io/nginxinc/nginx-unprivileged@sha256:bfcf1250dae73fb5dafe18b9fa64d033441510c5a2fc7a11cf8003087890301b
  ensure_image docker.io/hashicorp/vault@sha256:8af37ae9d45e4a0fac48ab700e0d99efc4c2d6cd84354a869f2147f1d3abab46
  podman image exists "localhost/acme-lego:$LEGO_IMAGE_TAG" || podman build -q \
    --build-arg UBI_IMAGE="$UBI_IMAGE" --build-arg LEGO_VERSION="$LEGO_VERSION" --build-arg LEGO_SHA256="$LEGO_SHA256" \
    --build-arg VAULT_VERSION="$VAULT_VERSION" --build-arg VAULT_SHA256="$VAULT_LINUX_SHA256" \
    -t "localhost/acme-lego:$LEGO_IMAGE_TAG" -f "$ROOT/podman/images/lego/Containerfile" "$ROOT/podman/images/lego" >/dev/null
  podman image exists localhost/acme-test-rhel-host:1 || podman build -q -t localhost/acme-test-rhel-host:1 "$ROOT/tests/podman/rhel-host" >/dev/null
  podman image exists localhost/acme-test-linux-client:1 || podman build -q --build-arg UBI_IMAGE="$UBI_IMAGE" \
    -t localhost/acme-test-linux-client:1 "$ROOT/tests/podman/linux-client" >/dev/null
}

PREPARE_ONLY=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --prepare-only) PREPARE_ONLY=1; shift ;;
esac
prepare
(( PREPARE_ONLY )) && exit 0
[[ $# -gt 0 ]] || set -- "$ROOT/tests/podman"
exec "$BATS" --timing "$@"
