# onboard-admin: palvelinten liittäminen ja poisto (onboard-server.sh).
# Palvelinkohtaiset policyt cert-<palvelin> ja AppRole-roolit.
path "sys/policies/acl/cert-*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl"        { capabilities = ["list"] }
path "auth/approle/role"       { capabilities = ["list"] }
path "auth/approle/role/*"     { capabilities = ["create", "read", "update", "delete", "list"] }
# role-id, secret-id (kääritty), secret-id-accessor/lookup ja /destroy kuuluvat yllä olevaan
path "sys/wrapping/lookup"     { capabilities = ["update"] }
path "secret/metadata/certs"   { capabilities = ["list"] }
path "secret/metadata/certs/*" { capabilities = ["read", "list"] }
