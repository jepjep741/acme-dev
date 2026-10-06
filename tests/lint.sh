#!/usr/bin/env bash
# Ajaa lintterit kiinnitetyistä konttiimageista (rakennusympäristö, ei asennuksia isäntään).
#   tests/lint.sh [shell|docker|yaml|compose|all]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=podman/versions.env
source "$ROOT/podman/versions.env"
PC=${PODMAN_COMPOSE:-podman-compose}
RUN=(podman run --rm --network none --security-opt label=disable -v "$ROOT:/src:ro" -w /src)

usage() { echo "Käyttö: $0 [shell|docker|yaml|compose|all]"; }

lint_shell() {
  echo "== shellcheck"
  mapfile -t files < <(cd "$ROOT" && find podman tests -name '*.sh' -o -name '*.bash' -o -name '*.bats' | sort)
  "${RUN[@]}" "$SHELLCHECK_IMAGE" -x --source-path=/src -s bash -S style "${files[@]}"
}

lint_docker() {
  echo "== hadolint"
  mapfile -t files < <(cd "$ROOT" && find podman tests -name 'Containerfile*' | sort)
  for f in "${files[@]}"; do "${RUN[@]}" --entrypoint hadolint "$HADOLINT_IMAGE" "$f"; done
}

lint_yaml() {
  echo "== yamllint"
  "${RUN[@]}" "$YAMLLINT_IMAGE" -c tests/yamllint.yaml podman tests
}

lint_compose() {
  echo "== podman-compose config"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  sed -e 's/<10.x.x.x>/10.0.0.10/' -e 's/<[^>]*>/test.example/g' "$ROOT/podman/.env.example" > "$tmp/.env"
  (cd "$ROOT/podman" && $PC --env-file "$tmp/.env" -f compose.yaml config >/dev/null)
  (cd "$ROOT/podman" && $PC --env-file "$tmp/.env" -f compose.yaml -f compose.eab.yaml config >/dev/null)
  echo "compose.yaml ja compose.eab.yaml: OK"
}

case "${1:-all}" in
  shell) lint_shell ;;
  docker) lint_docker ;;
  yaml) lint_yaml ;;
  compose) lint_compose ;;
  all) lint_shell; lint_docker; lint_yaml; lint_compose ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
