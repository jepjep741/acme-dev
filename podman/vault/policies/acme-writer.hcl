# acme-writer: keskuspalvelimen lego-hookin token. Vain varmenteiden kirjoitus.
# (keskus/policies.hcl + metadata patch/list voimassaolon kirjaamiseen custom_metadataan)
path "secret/data/certs/*"     { capabilities = ["create", "update"] }
path "secret/metadata/certs/*" { capabilities = ["read", "list", "patch"] }  # patch: custom_metadata not_after
path "secret/metadata/certs"   { capabilities = ["list"] }
