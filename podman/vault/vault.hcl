# Vault-palvelin (kontti, isännän verkko). Ympäristökohtaiset osoitteet tulevat ympäristöstä
# (compose.yaml / .env), joten tämä tiedosto on sama kaikissa asennuksissa:
#   VAULT_API_ADDR      esim. https://vault.asiakas.fi:8200  (agenttien käyttämä osoite)
#   VAULT_CLUSTER_ADDR  https://127.0.0.1:8201               (raft, yksi solmu)
# Listener (VAULT_BIND_IP:VAULT_PUBLISH_PORT, TLS) muodostetaan käynnistyksessä: compose.yaml.

ui            = false
disable_mlock = true      # HashiCorpin suositus integroidun tallennuksen (raft) kanssa

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

# Audit-loki otetaan käyttöön vault-init.sh:lla: file_path=/vault/logs/audit.log
