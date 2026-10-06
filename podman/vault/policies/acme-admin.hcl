# acme-admin: ylläpitäjät. DVV:n EAB-avaimet ja legon ACME-tilin varmuuskopio (secret/acme/*),
# varmenteiden tila (luku). (keskus/policies.hcl + luku secret/certs)
path "secret/data/acme/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/acme/*" { capabilities = ["read", "list", "delete"] }
path "secret/metadata/certs"   { capabilities = ["list"] }
path "secret/metadata/certs/*" { capabilities = ["read", "list"] }
path "secret/data/pki/*"      { capabilities = ["read"] }
