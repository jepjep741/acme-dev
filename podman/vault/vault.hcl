# Vault-palvelin (kontti). Ympäristökohtaiset osoitteet tulevat ympäristömuuttujista
# (compose.yaml / .env), joten tämä tiedosto on sama kaikissa asennuksissa:
#   VAULT_API_ADDR      esim. https://vault.asiakas.fi:8200  (agenttien käyttämä osoite)
#   VAULT_CLUSTER_ADDR  https://vault:8201                   (raft, kontin sisäinen)

ui            = false
disable_mlock = true      # HashiCorpin suositus integroidun tallennuksen (raft) kanssa

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

listener "tcp" {
  address            = "0.0.0.0:8200"
  cluster_address    = "0.0.0.0:8201"
  tls_cert_file      = "/vault/tls/vault.crt"       # palvelinvarmenne + välivarmenteet
  tls_key_file       = "/run/secrets/vault_tls_key" # podman secret
  tls_min_version    = "tls12"
  tls_disable        = false
}

# Audit-loki otetaan käyttöön vault-init.sh:lla: file_path=/vault/logs/audit.log
