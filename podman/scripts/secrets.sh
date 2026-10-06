#!/usr/bin/env bash
# Podman secretien luonti ja kierrätys (palvelukäyttäjänä). Arvot eivät kulje komentorivillä,
# ympäristömuuttujissa eivätkä tulosteessa.
#
#   secrets.sh list                       salaisuuksien nimet ja luontiajat (ei arvoja)
#   secrets.sh vault-token [--rotate]     acme-writer-token (lego-hook) token-roolilla -> vault_token
#   secrets.sh snapshot-token [--rotate]  snapshot-token (backup.sh) -> snapshot_token
#   secrets.sh eab                        DVV:n EAB KID/HMAC (piilotettu syöte) -> lego_eab_kid/_hmac
#   secrets.sh eab-remove                 poista EAB-salaisuudet ACME-tilin luonnin jälkeen
#   secrets.sh eab-to-vault               tallenna EAB Vaultiin secret/acme/dvv-eab (acme-admin)
#   secrets.sh lego-account-to-vault      legon ACME-tili (accounts/) Vaultiin secret/acme/lego-account
#
# Ylläpitäjän token: kirjautuminen (userpass + TOTP) tai VAULT_ADMIN_TOKEN_FILE.
# Ilman --rotate olemassa oleva voimassa oleva token säilytetään (idempotentti).
# --rotate: uusi token -> secret, vanha mitätöidään accessorin kautta.
set -euo pipefail
LOG_TAG=secrets
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}; [[ $# -gt 0 ]] && shift
ROTATE=0
for a in "$@"; do
  case "$a" in
    --rotate) ROTATE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# Onko secretissä voimassa oleva Vault-token? (token lookup-self)
token_valid() {
  podman secret exists "$1" || return 1
  get_secret "$1" | { IFS= read -r t; printf '%s\n' "$t"; } |
    podman exec -i "$VAULT_CONTAINER" sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; vault token lookup >/dev/null 2>&1'
}

token_accessor() {
  get_secret "$1" | { IFS= read -r t; printf '%s\n' "$t"; } |
    podman exec -i "$VAULT_CONTAINER" sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; vault token lookup -format=json' 2>/dev/null |
    json_get 'd["data"]["accessor"]'
}

service_token() { # service_token <token-rooli> <secret-nimi>
  local role=$1 name=$2 tok old=""
  vault_running || die "$VAULT_CONTAINER ei ole käynnissä"
  vault_is_sealed && die "Vault on sinetöity: vault-unseal.sh"
  if token_valid "$name" && (( ! ROTATE )); then
    log "$name: voimassa oleva token säilytetään (--rotate vaihtaa)"; return 0
  fi
  if (( ROTATE )) && token_valid "$name"; then old=$(token_accessor "$name" || true); fi
  vault_admin_token tok
  vault_tok "$tok" token create -role="$role" -field=token </dev/null | put_secret "$name"
  token_valid "$name" || die "$name: uusi token ei toimi"
  log "$name: uusi token tallennettu (rooli $role)"
  if [[ -n "$old" ]]; then
    printf '%s' "$old" | vault_tok "$tok" write auth/token/revoke-accessor accessor=- >/dev/null
    log "$name: vanha token mitätöity"
  fi
  if [[ "$name" == vault_token ]] && podman container exists acme-vault; then
    log "Huom: lego-kontti lukee uuden tokenin seuraavalla ajolla."
  fi
}

cmd_eab() {
  local kid hmac
  read_secret kid "DVV:n EAB KID"
  read_secret hmac "DVV:n EAB HMAC"
  [[ -n "$kid" && -n "$hmac" ]] || die "KID ja HMAC vaaditaan"
  printf '%s' "$kid" | put_secret lego_eab_kid
  printf '%s' "$hmac" | put_secret lego_eab_hmac
  unset kid hmac
  log "EAB-salaisuudet tallennettu. Ensimmäinen ajo: ACME_COMPOSE_FILES=compose.eab.yaml acme-compose.sh --profile jobs run --rm -T lego"
}

cmd_eab_remove() {
  local n
  for n in lego_eab_kid lego_eab_hmac; do
    if podman secret exists "$n"; then podman secret rm "$n" >/dev/null; log "$n poistettu"; fi
  done
}

cmd_eab_to_vault() {
  local tok
  if ! podman secret exists lego_eab_kid || ! podman secret exists lego_eab_hmac; then
    die "EAB-salaisuudet puuttuvat (secrets.sh eab)"
  fi
  vault_admin_token tok
  # kv put lukee kentät stdinistä JSON:na: {"kid": ..., "hmac": ...}
  python3 -c 'import sys,json
kid=sys.stdin.readline().rstrip("\n"); hmac=sys.stdin.readline().rstrip("\n")
print(json.dumps({"kid": kid, "hmac": hmac}))' < <(get_secret lego_eab_kid; printf '\n'; get_secret lego_eab_hmac; printf '\n') |
    vault_tok "$tok" kv put secret/acme/dvv-eab - >/dev/null
  log "EAB tallennettu Vaultiin: secret/acme/dvv-eab"
}

cmd_lego_account_to_vault() {
  local tok img
  img=$(env_get LEGO_IMAGE); [[ -n "$img" ]] || die "LEGO_IMAGE puuttuu .env:stä"
  vault_admin_token tok
  podman run --rm --log-driver none -v acme_lego-data:/d:ro --entrypoint sh "$img" \
    -c 'cd /d && tar -czf - accounts | base64 -w0' |
    python3 -c 'import sys,json; print(json.dumps({"archive": sys.stdin.read()}))' |
    vault_tok "$tok" kv put secret/acme/lego-account - >/dev/null
  log "Legon ACME-tili tallennettu Vaultiin: secret/acme/lego-account"
}

case "$CMD" in
  list) podman secret ls --format '{{.Name}}\t{{.CreatedAt}}' | grep -E '^(vault_token|snapshot_token|vault_tls_key|lego_eab_kid|lego_eab_hmac)\b' || true ;;
  vault-token) service_token acme-writer vault_token ;;
  snapshot-token) service_token snapshot snapshot_token ;;
  eab) cmd_eab ;;
  eab-remove) cmd_eab_remove ;;
  eab-to-vault) cmd_eab_to_vault ;;
  lego-account-to-vault) cmd_lego_account_to_vault ;;
  -h|--help|"") usage; [[ -n "$CMD" ]] ;;
  *) usage >&2; exit 2 ;;
esac
