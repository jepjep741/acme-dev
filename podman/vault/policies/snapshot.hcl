# snapshot: vault-snapshot.timer (backup.sh). Vain raft-snapshotin luku.
path "sys/storage/raft/snapshot" { capabilities = ["read"] }
