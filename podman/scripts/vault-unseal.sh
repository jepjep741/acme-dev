#!/usr/bin/env bash
# Vaultin avaus (unseal) uudelleenkäynnistyksen jälkeen. Ajetaan palvelukäyttäjänä.
# Kysyy avainosat piilotettuna yksi kerrallaan, kunnes kynnys täyttyy. Mitään ei tallenneta:
# avainosa kulkee stdinin kautta suoraan vault-konttiin (ei komentoriville, ei lokeihin).
#
#   vault-unseal.sh            # interaktiivinen; kukin haltija syöttää oman osansa
#   vault-unseal.sh --status   # näytä tila
#   vault-unseal.sh --reset    # nollaa keskeneräinen avaus (esim. väärä osa syötetty)
# Ilman TTY:tä avainosat luetaan stdinistä rivi kerrallaan (automaatio/testit).
set -euo pipefail
LOG_TAG=vault-unseal
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; }

status_line() {
  vault_status_json 2>/dev/null | json_get '"alustettu=%s sinetöity=%s edistyminen=%s/%s" % (d["initialized"], d["sealed"], d.get("progress",0), d.get("t",0))'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --status) vault_running || die "$VAULT_CONTAINER ei ole käynnissä"; status_line; exit 0 ;;
  --reset)
    printf '{"reset": true}' | vault_anon write sys/unseal - >/dev/null; log "Keskeneräinen avaus nollattu."; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

vault_running || die "$VAULT_CONTAINER ei ole käynnissä. Käynnistä: systemctl --user start acme-stack"
vault_is_initialized || die "Vaultia ei ole alustettu: vault-init.sh init"
if ! vault_is_sealed; then log "Vault on jo avattu."; exit 0; fi

n=0
while vault_is_sealed; do
  st=$(vault_status_json 2>/dev/null || true)
  prog=$(json_get 'd.get("progress",0)' <<< "$st"); thr=$(json_get 'd["t"]' <<< "$st")
  key=""
  read_secret key "Avainosa ($((prog + 1))/$thr)"
  if [[ -z "$key" ]]; then
    [[ -t 0 ]] && { log "Tyhjä syöte, yritä uudelleen."; continue; }
    die "avainosat loppuivat ennen kuin kynnys täyttyi (edistyminen $prog/$thr)"
  fi
  if ! printf '%s' "$key" | vault_anon write -format=json sys/unseal key=- >/dev/null 2>&1; then
    unset key
    log "Avainosa hylättiin (väärä muoto tai osa). Keskeneräinen avaus säilyy; --reset nollaa sen."
    [[ -t 0 ]] || exit 1
    continue
  fi
  unset key
  n=$((n + 1))
done
log "Vault avattu ($n avainosaa syötetty). Tarkista: healthcheck.sh"
