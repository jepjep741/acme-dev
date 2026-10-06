# acme-writer: keskuspalvelimen lego-hookin token. Vain varmenteiden kirjoitus.
# (keskus/policies.hcl, sama sisältö)
path "secret/data/certs/*"     { capabilities = ["create", "update"] }
path "secret/metadata/certs/*" { capabilities = ["read", "list"] }
