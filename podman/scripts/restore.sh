#!/usr/bin/env bash
# Palautus backup.sh:n varmuuskopiosta (palvelukäyttäjänä). Tarkistaa SHA256SUMS:n ensin.
#
#   restore.sh verify DIR                tarkista tarkistussummat
#   restore.sh vault DIR [--yes]         raft-snapshot. Jos Vault on alustamaton (uusi asennus),
#                                        alustetaan väliaikaisesti ja palautetaan -force; sen jälkeen
#                                        Vault avataan ALKUPERÄISILLÄ avainosilla (vault-unseal.sh).
#                                        Alustetussa Vaultissa vaatii ylläpitäjän (vault-admin).
#   restore.sh lego-data DIR [--yes]     korvaa acme_lego-data-volyymin (gpg --decrypt jos .gpg)
#   restore.sh config DIR --to HAKEMISTO pura konfiguraatio tarkasteltavaksi (ei ylikirjoita /etc:iä)
set -euo pipefail
LOG_TAG=restore
# shellcheck source=podman/scripts/lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}; [[ $# -gt 0 ]] && shift
DIR="" YES=0 TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --to) TO=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) DIR=$1; shift ;;
  esac
done
[[ "$CMD" == -h || "$CMD" == --help ]] && { usage; exit 0; }
[[ -n "$DIR" && -d "$DIR" ]] || { usage >&2; exit 2; }

verify() {
  [[ -r "$DIR/SHA256SUMS" ]] || die "$DIR/SHA256SUMS puuttuu"
  (cd "$DIR" && sha256sum --quiet -c SHA256SUMS) || die "tarkistussummat eivät täsmää: varmuuskopio on vioittunut tai muutettu"
  log "Tarkistussummat OK: $DIR"
}

confirm() {
  (( YES )) && return 0
  [[ -t 0 ]] || die "vahvistus vaaditaan: aja päätteeltä tai anna --yes"
  local a; read -r -p "$1 Kirjoita PALAUTA jatkaaksesi: " a
  [[ "$a" == PALAUTA ]] || die "keskeytetty"
}

restore_vault() {
  verify
  vault_running || die "$VAULT_CONTAINER ei ole käynnissä"
  local tok resp k fresh=0
  if ! vault_is_initialized; then
    fresh=1
    log "Vault on alustamaton: alustetaan väliaikaisesti (1/1) palautusta varten. Väliaikaiset avaimet hävitetään."
    resp=$(vault_anon operator init -key-shares=1 -key-threshold=1 -format=json </dev/null)
    k=$(json_get 'd["unseal_keys_b64"][0]' <<< "$resp"); tok=$(json_get 'd["root_token"]' <<< "$resp"); unset resp
    printf '%s' "$k" | vault_anon write sys/unseal key=- >/dev/null; unset k
    for _ in $(seq 30); do vault_is_sealed || break; sleep 1; done
  else
    vault_is_sealed && die "Vault on sinetöity: avaa ensin (vault-unseal.sh) tai palauta uuteen asennukseen"
    confirm "Vaultin NYKYINEN data korvataan snapshotilla $DIR/vault.snap."
    vault_admin_token tok
  fi
  { printf '%s\n' "$tok"; cat "$DIR/vault.snap"; } |
    podman exec -i "$VAULT_CONTAINER" sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN
      f=/tmp/restore-$$.snap; cat > "$f"; vault operator raft snapshot restore -force "$f"; rc=$?; rm -f "$f"; exit $rc'
  unset tok
  log "Snapshot palautettu. Vault käyttää nyt ALKUPERÄISIÄ avainosia ja tunnuksia."
  if (( fresh )); then
    # Vault pitää väliaikaisen avausasetuksen (1/1) muistissa, kunnes se käynnistetään
    # uudelleen; vasta sitten alkuperäiset avainosat kelpaavat.
    log "Käynnistetään Vault uudelleen, jotta alkuperäinen avausasetus otetaan käyttöön."
    podman restart "$VAULT_CONTAINER" >/dev/null
    for _ in $(seq 60); do vault_status_json >/dev/null 2>&1 && break; sleep 1; done
  fi
  if vault_is_sealed; then
    log "Vault on sinetöity: avaa alkuperäisillä avainosilla: vault-unseal.sh"
  fi
}

restore_lego_data() {
  verify
  local src tmp
  if [[ -r "$DIR/lego-data.tar.gpg" ]]; then
    tmp=$(mktemp); chmod 600 "$tmp"; trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' RETURN
    gpg --batch --quiet --decrypt --output "$tmp" --yes "$DIR/lego-data.tar.gpg" || die "lego-data.tar.gpg:n purku epäonnistui (yksityinen avain?)"
    src=$tmp
  elif [[ -r "$DIR/lego-data.tar" ]]; then
    src="$DIR/lego-data.tar"
  else
    die "lego-data.tar(.gpg) puuttuu"
  fi
  if podman ps --format '{{.Names}}' | grep -q 'lego'; then die "lego-kontti on käynnissä; odota ajon päättymistä"; fi
  confirm "Volyymi acme_lego-data korvataan."
  podman volume rm -f acme_lego-data >/dev/null 2>&1 || true
  podman volume create --opt o=uid=1000,gid=1000 acme_lego-data >/dev/null
  podman volume import acme_lego-data "$src"
  log "acme_lego-data palautettu. Tarkista: acme-compose.sh --profile jobs run --rm -T lego --dry-run"
}

restore_config() {
  verify
  [[ -n "$TO" ]] || die "--to HAKEMISTO vaaditaan (ei ylikirjoiteta /etc/acme-podman automaattisesti)"
  mkdir -p "$TO"; tar -C "$TO" -xf "$DIR/config.tar"
  log "Konfiguraatio purettu: $TO. Vertaa ja kopioi rootina: diff -r $TO /etc/acme-podman"
}

case "$CMD" in
  verify) verify ;;
  vault) restore_vault ;;
  lego-data) restore_lego_data ;;
  config) restore_config ;;
  *) usage >&2; exit 2 ;;
esac
