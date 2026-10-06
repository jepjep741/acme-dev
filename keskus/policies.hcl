# --- Keskuspalvelimen deploy-hookin policy: vain varmenteiden kirjoitus ---
#   vault policy write acme-writer - <<< (tämä osio)
path "secret/data/certs/*"     { capabilities = ["create", "update"] }
path "secret/metadata/certs/*" { capabilities = ["read", "list"] }

# --- Ylläpitäjien policy DVV:n EAB-avaimille ja ACME-tilin varmuuskopiolle ---
#   vault policy write acme-admin - <<< (alla oleva)
# path "secret/data/acme/*"     { capabilities = ["create", "read", "update", "delete"] }
# path "secret/metadata/acme/*" { capabilities = ["read", "list", "delete"] }
#
# Tallennus:
#   vault kv put secret/acme/dvv-eab kid=<KID> hmac=<HMAC>
#   tar -C /var/lib/lego -czf - accounts | base64 -w0 > /tmp/acct.b64
#   vault kv put secret/acme/lego-account archive=@/tmp/acct.b64 && shred -u /tmp/acct.b64

# --- Palvelinkohtaiset policyt luo onboard-server.sh:  cert-<palvelin> ---
# path "secret/data/certs/<nimi>" { capabilities = ["read"] }

# --- Vaultin perusasetukset (ajetaan kerran ylläpitäjänä) ---
# vault audit enable file file_path=/var/log/vault/audit.log
# vault secrets enable -path=secret -version=2 kv
# vault auth enable approle
# vault kv metadata put -max-versions=10 secret/certs   (versiohistoria palautusta varten)
