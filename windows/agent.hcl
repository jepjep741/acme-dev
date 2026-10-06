# C:\ProgramData\vault-agent\agent.hcl
# Agentti ajetaan virtuaalitilillä NT SERVICE\vault-agent (ei SYSTEM),
# ja se kirjoittaa vain staging-hakemistoon. Asennuksen tekee SYSTEM-tehtävä.
pid_file = "C:/ProgramData/vault-agent/run/pid"

vault {
  address = "https://vault.asiakas.fi:8200"
  ca_cert = "C:/ProgramData/vault-agent/ca.pem"
  retry { num_retries = 5 }
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "C:/ProgramData/vault-agent/role_id"
      secret_id_file_path                 = "C:/ProgramData/vault-agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template_config {
  static_secret_render_interval = "1h"
  exit_on_retry_failure         = false
}

# Yksi tiedosto: rivi 1 = PFX:n salasana, rivi 2 = PFX base64-muodossa.
# Molemmat samassa tiedostossa -> päivittyvät aina yhtä aikaa (atominen kirjoitus).
template {
  contents             = "{{ with secret \"secret/data/certs/intranet\" }}{{ .Data.data.pfx_password }}\n{{ .Data.data.pfx_b64 }}{{ end }}"
  destination          = "C:/ProgramData/vault-agent/staging/intranet.pfx.txt"
  error_on_missing_key = true
}
