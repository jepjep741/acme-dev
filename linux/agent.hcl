# /etc/vault-agent/agent.hcl  -  omistaja root:vault-agent, 0640
# Agentti ajetaan omana käyttäjänään (vault-agent), ei rootina.
# Ei listeneriä eikä token-sinkkiä: Vault-token on vain agentin muistissa.

pid_file = "/run/vault-agent/pid"

vault {
  address = "https://vault.asiakas.fi:8200"
  ca_cert = "/etc/vault-agent/ca.pem"       # vain oma CA, ei järjestelmän luottamusketjua
  retry { num_retries = 5 }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role_id"    # root:vault-agent 0440
      secret_id_file_path                 = "/etc/vault-agent/secret_id"  # root:vault-agent 0440
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "1h"
  exit_on_retry_failure         = false
}

# Agentti kirjoittaa VAIN staging-hakemistoon (atominen kirjoitus: temp + rename).
# Asennuksen tuotantopolkuun tekee erillinen root-palvelu tarkistusten jälkeen.
# Yksi template per varmenne; nimi = Vaultin polun nimi.
template {
  contents             = "{{ with secret \"secret/data/certs/intranet\" }}{{ .Data.data.bundle }}{{ end }}"
  destination          = "/var/lib/vault-agent/staging/intranet.pem"
  perms                = "0640"
  error_on_missing_key = true
}
