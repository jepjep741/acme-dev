# vault-admin: Vaultin ylläpito ilman root-tokenia (vault-init.sh configure, secrets.sh, restore.sh).
# Vain MFA:lla kirjautuville ylläpitäjille. Ei pääsyä varmenteiden avaimiin (secret/data/certs).
path "sys/mounts"              { capabilities = ["read"] }
path "sys/mounts/*"            { capabilities = ["create", "read", "update", "sudo"] }
path "sys/auth"                { capabilities = ["read"] }
path "sys/auth/*"              { capabilities = ["create", "read", "update", "sudo"] }
path "sys/audit"               { capabilities = ["read", "sudo"] }
path "sys/audit/*"             { capabilities = ["create", "read", "update", "sudo"] }
path "sys/policies/acl"        { capabilities = ["list"] }
path "sys/policies/acl/*"      { capabilities = ["create", "read", "update", "list"] }
path "secret/config"           { capabilities = ["read", "update"] }
# Palvelutokenit token-roolien kautta (ei orpo-oikeutta yleisesti)
path "auth/token/roles/*"      { capabilities = ["create", "read", "update", "list"] }
path "auth/token/create/acme-writer" { capabilities = ["update"] }
path "auth/token/create/snapshot"    { capabilities = ["update"] }
path "auth/token/lookup-accessor"    { capabilities = ["update"] }
path "auth/token/revoke-accessor"    { capabilities = ["update"] }
# Ylläpitäjätunnukset ja MFA
path "auth/userpass/users/*"   { capabilities = ["create", "read", "update", "delete", "list"] }
path "identity/entity"         { capabilities = ["create", "update"] }
path "identity/entity/*"       { capabilities = ["create", "read", "update", "list"] }
path "identity/entity-alias"   { capabilities = ["create", "update"] }
path "identity/lookup/entity"  { capabilities = ["update"] }
path "identity/mfa/method/totp"   { capabilities = ["create", "update", "list"] }
path "identity/mfa/method/totp/*" { capabilities = ["create", "read", "update"] }
path "identity/mfa/login-enforcement/*" { capabilities = ["create", "read", "update"] }
# Raft: snapshot ja palautus (restore.sh)
path "sys/storage/raft/snapshot"       { capabilities = ["read", "update"] }
path "sys/storage/raft/snapshot-force" { capabilities = ["update"] }
path "sys/storage/raft/configuration"  { capabilities = ["read"] }
# Root-tokenin generointi hätätilanteessa vaatii avainosat (generate-root), ei policyä.
