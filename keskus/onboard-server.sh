#!/usr/bin/env bash
# Liittää palvelimen jakeluun tai kierrättää sen secret_id:n.
# Ajetaan YLLÄPITÄJÄN Vault-tunnuksella (ei deploy-hookin tokenilla).
#
#   ./onboard-server.sh web01 10.1.2.31 intranet api
#
# Tulostaa role_id:n ja KÄÄRITYN (response-wrapped) secret_id:n. Kääre on
# kertakäyttöinen ja vanhenee 15 min:ssa. Se puretaan KOHDEPALVELIMELLA
# (esim. Ansiblella):  VAULT_TOKEN=<kääre> vault unwrap -field=secret_id
# Jos purku epäonnistuu "already used" -virheeseen, joku on siepannut
# kääreen -> älä ota käyttöön, selvitä ja luo uusi.
set -euo pipefail
SERVER="$1"; IP="$2"; shift 2; CERTS=("$@")
[[ "$SERVER" =~ ^[a-z0-9-]+$ ]] || { echo "Virheellinen palvelimen nimi" >&2; exit 1; }

POLICY=""
for c in "${CERTS[@]}"; do
  [[ "$c" =~ ^[a-z0-9-]+$ ]] || { echo "Virheellinen varmenteen nimi: $c" >&2; exit 1; }
  POLICY+="path \"secret/data/certs/$c\" { capabilities = [\"read\"] }"$'\n'
done
echo "$POLICY" | vault policy write "cert-$SERVER" -

vault write "auth/approle/role/$SERVER" \
  token_policies="cert-$SERVER" \
  token_ttl=1h token_max_ttl=24h \
  token_bound_cidrs="$IP/32" \
  secret_id_bound_cidrs="$IP/32" \
  secret_id_ttl=2160h \
  secret_id_num_uses=0 >/dev/null

ROLE_ID=$(vault read -field=role_id "auth/approle/role/$SERVER/role-id")
WRAPPED=$(vault write -wrap-ttl=15m -f -field=wrapping_token "auth/approle/role/$SERVER/secret-id")

echo "role_id:            $ROLE_ID"
echo "wrapped secret_id:  $WRAPPED   (voimassa 15 min, kertakäyttöinen)"
echo
echo "Kierrätys: aja skripti uudelleen, vie uusi secret_id palvelimelle, käynnistä agentti"
echo "uudelleen ja hävitä vanha:  vault list auth/approle/role/$SERVER/secret-id"
echo "                            vault write auth/approle/role/$SERVER/secret-id-accessor/destroy secret_id_accessor=<vanha>"
