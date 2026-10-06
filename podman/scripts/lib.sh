# shellcheck shell=bash
# Yhteiset funktiot keskuksen ylläpitoskripteille (source). Ajetaan palvelukäyttäjänä (acmesvc).
#
# Periaatteet (CLAUDE.md):
#  - Vault-komennot ajetaan vault-kontissa (podman exec). Token ja muut salaisuudet kulkevat
#    AINA stdinin kautta: ei komentoriville, ei ympäristömuuttujiin podman exec -e:llä,
#    ei podman inspectiin, ei levylle.
#  - Salaisuudet luetaan TTY:ltä piilotettuna tai (automaatio/testit) stdinistä rivi kerrallaan.
#  - podman run -konttien tuloste menee journaldiin: salaisuuksia ei tulosteta niiden kautta.

VAULT_CONTAINER=${VAULT_CONTAINER:-acme-vault}
ACME_ENV=${ACME_ENV:-/etc/acme-podman/.env}
# shellcheck disable=SC2034  # käytetään skripteissä, jotka sourcettavat tämän
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s: %s\n' "${LOG_TAG:-acme}" "$*" >&2; }
die() { log "VIRHE: $*"; exit 1; }

# Arvo .env:stä (KEY=arvo  # kommentti). Ei sourcea: .env ei ole suoritettava tiedosto.
env_get() { [[ -r "$ACME_ENV" ]] && sed -n "s/^$1=\([^ #]*\).*/\1/p" "$ACME_ENV" | tail -1; }

# Lukee salaisuuden: TTY:ltä piilotettuna kehotteella, muuten rivin stdinistä.
# read_secret <muuttuja> <kehote>
read_secret() {
  local __v=$1 __p=$2 __s=""   # kutsuja ei saa käyttää nimiä __v/__p/__s
  if [[ -t 0 ]]; then
    read -rs -p "$__p: " __s; printf '\n' >&2
  else
    IFS= read -r __s || true
  fi
  printf -v "$__v" '%s' "$__s"
}

# Tavallinen (ei-salainen) syöte: kehote TTY:llä, muuten rivi stdinistä.
read_plain() {
  local __v=$1 __p=$2 __s=""
  if [[ -t 0 ]]; then read -r -p "$__p: " __s; else IFS= read -r __s || true; fi
  printf -v "$__v" '%s' "$__s"
}

json_get() { # json_get <python-lauseke d:lle>  (stdin = JSON)
  python3 -c 'import sys,json
d=json.load(sys.stdin)
try:
    v=eval(sys.argv[1])
except (KeyError, TypeError, IndexError):
    sys.exit(3)
print(v if not isinstance(v,(dict,list)) else json.dumps(v))' "$1"
}

vault_running() {
  podman container exists "$VAULT_CONTAINER" &&
    [[ "$(podman inspect -f '{{.State.Running}}' "$VAULT_CONTAINER")" == true ]]
}

# Vault-komento ilman tokenia (status, unseal, init, login). stdin välitetään.
vault_anon() { podman exec -i -e VAULT_TOKEN= "$VAULT_CONTAINER" vault "$@"; }

# Vault-komento tokenilla. Token stdinin 1. rivinä, loput stdinistä vaultille.
# vault_tok <token> <vault-argumentit...>   (kutsuja ohjaa stdinin, esim. </dev/null)
vault_tok() {
  local tok=$1; shift
  { printf '%s\n' "$tok"; cat; } |
    podman exec -i "$VAULT_CONTAINER" sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"
}

# Vaultin tila JSON:na (sealed/initialized). vault status palauttaa 2, kun Vault on sinetöity:
# se ei ole virhe (pipefail-putkissa muuten tulkittaisiin väärin). 1 = Vault ei vastaa.
vault_status_json() {
  local rc=0
  vault_anon status -format=json </dev/null || rc=$?
  (( rc == 0 || rc == 2 ))
}

vault_is_initialized() { vault_status_json 2>/dev/null | json_get 'd["initialized"]' | grep -qx True; }
vault_is_sealed() { vault_status_json 2>/dev/null | json_get 'd["sealed"]' | grep -qx True; }

# Ylläpitäjän kirjautuminen: userpass + TOTP (login MFA). Tulostaa tokenin muuttujaan.
# vault_login_admin <muuttuja>   (kysyy käyttäjätunnuksen, salasanan ja TOTP-koodin)
# Paikalliset muuttujat on nimetty _vla_-etuliitteellä: printf -v kirjoittaisi muuten
# samannimiseen paikalliseen muuttujaan eikä kutsujan muuttujaan (bashin dynaaminen näkyvyys).
vault_login_admin() {
  local _vla_out=$1 _vla_user _vla_pw _vla_code _vla_resp _vla_req _vla_mid _vla_tok
  read_plain _vla_user "Vault-käyttäjätunnus"
  [[ "$_vla_user" =~ ^[a-z0-9._-]+$ ]] || die "virheellinen käyttäjätunnus"
  read_secret _vla_pw "Salasana"
  _vla_resp=$(printf '%s' "$_vla_pw" | vault_anon write -format=json "auth/userpass/login/$_vla_user" password=- 2>/dev/null) ||
    { unset _vla_pw; die "kirjautuminen epäonnistui (tunnus/salasana)"; }
  unset _vla_pw
  if _vla_tok=$(json_get 'd["auth"]["client_token"] or ""' <<< "$_vla_resp") && [[ -n "$_vla_tok" ]]; then
    printf -v "$_vla_out" '%s' "$_vla_tok"; return 0   # ei MFA-vaatimusta (ei pitäisi tapahtua tuotannossa)
  fi
  _vla_req=$(json_get 'd["auth"]["mfa_requirement"]["mfa_request_id"]' <<< "$_vla_resp") || die "odottamaton kirjautumisvastaus"
  _vla_mid=$(json_get 'list(d["auth"]["mfa_requirement"]["mfa_constraints"].values())[0]["any"][0]["id"]' <<< "$_vla_resp") ||
    die "MFA-menetelmää ei löytynyt vastauksesta"
  read_secret _vla_code "TOTP-koodi"
  [[ "$_vla_code" =~ ^[0-9]{6}$ ]] || die "TOTP-koodin on oltava 6 numeroa"
  _vla_tok=$(printf '{"mfa_request_id":"%s","mfa_payload":{"%s":["%s"]}}' "$_vla_req" "$_vla_mid" "$_vla_code" |
    vault_anon write -format=json sys/mfa/validate - 2>/dev/null | json_get 'd["auth"]["client_token"]' 2>/dev/null) ||
    die "TOTP-tarkistus epäonnistui (väärä, jo käytetty tai vanhentunut koodi; tarkista kello)"
  printf -v "$_vla_out" '%s' "$_vla_tok"
}

# Token joko ympäristöstä VAULT_ADMIN_TOKEN_FILE (automaatio/testit, tiedosto 0600) tai kirjautumalla.
vault_admin_token() {
  local _vat_out=$1 _vat_tok
  if [[ -n "${VAULT_ADMIN_TOKEN_FILE:-}" ]]; then
    [[ -r "$VAULT_ADMIN_TOKEN_FILE" ]] || die "VAULT_ADMIN_TOKEN_FILE ei ole luettavissa"
    _vat_tok=$(tr -d '\r\n' < "$VAULT_ADMIN_TOKEN_FILE")
  else
    vault_login_admin _vat_tok
  fi
  printf -v "$_vat_out" '%s' "$_vat_tok"
}

# Kirjoittaa stdinin podman secretiksi (korvaa olemassa olevan).
put_secret() { podman secret create --replace "$1" - >/dev/null; }

# Podman secretin arvo (palvelukäyttäjän oma salaisuussäilö). Vain putkeen, ei tulosteeseen.
get_secret() { podman secret inspect --showsecret --format '{{.SecretData}}' "$1"; }
