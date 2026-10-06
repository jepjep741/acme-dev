# Runbook: häiriötilanteet ja niiden korjaus

Keskuspalvelimen (podman) häiriöt. Windows-palvelinten ongelmat: [windows-liittaminen.md](windows-liittaminen.md#7-vianmääritys).
Merkinnät ja palvelukäyttäjän kuori: [keskuspalvelin-podman.md](keskuspalvelin-podman.md#komennot-palvelukäyttäjänä).

**Ensimmäinen askel aina:**
```
acmesvc$ scripts/healthcheck.sh
acmesvc$ scripts/acme-compose.sh ps
acmesvc$ journalctl --user --since -1h -t acme-renew -t acme-deploy -t acme-vault -t acme-nginx
```
Tukea varten: `scripts/collect-diagnostics.sh` (arkisto ilman salaisuuksia).

---

## R1. Vault on sinetöity
**Oire:** healthcheck "Vault: SINETÖITY"; agenttien lokissa `503 Vault is sealed`; uusinnan lokissa
"Vault-tokenin uusinta epäonnistui".
**Syy:** keskus tai kontti käynnistyi uudelleen (normaalia), tai Vault sinetöi itsensä virheen takia.
**Korjaus:** kynnyksen verran avainosien haltijoita: `scripts/vault-unseal.sh`. Väärä osa: `--reset`
ja uudelleen. Selvitä syy: `journalctl --user -t acme-vault --since -1d | grep -E 'ERROR|seal'`.
Varmenteet palvelimilla toimivat sinetöinnin ajan; uudet eivät jakeudu.

## R2. Vault ei käynnisty
| Lokissa (`-t acme-vault`) | Syy | Korjaus |
|---|---|---|
| `error loading TLS cert` / `permission denied /run/secrets/vault_tls_key` | salaisuus puuttuu tai TLS-varmenne/avain eivät täsmää | `podman secret ls`; `tls-init.sh generate ... --renew` |
| `x509: certificate has expired` (agenttien lokissa) | Vaultin palvelinvarmenne vanhentunut | Palauta CA-avain offline-säilöstä `tls/private/ca.key`:ksi, `tls-init.sh generate --dir /etc/acme-podman/tls --dns ... --ip ... --renew`, `acme-compose.sh up -d --force-recreate vault`, avaa, poista CA-avain |
| `address already in use` | jokin muu kuuntelee `VAULT_BIND_IP:8200` | `ss -ltnp 'sport = :8200'` |
| `bind: cannot assign requested address` | `VAULT_BIND_IP` ei ole isännän osoite | korjaa `.env` |
| Kontti `Exited` 3 yrityksen jälkeen | `restart: on-failure:3` pysäytti | korjaa syy, `acme-compose.sh up -d vault` |
| SELinux `avc: denied` (`ausearch -m avc -ts recent`) | konteksti puuttuu | `root# install-host.sh install ...` (restorecon) |

## R3. Uusinta epäonnistuu
Tarkista: `journalctl --user -t acme-renew -n 100`.

| Lokissa | Syy | Korjaus |
|---|---|---|
| `dial tcp ...: i/o timeout` / `connection refused` DVV:hen | ulosmeno estetty, DNS tai välityspalvelin | `scripts/egress-check.sh`; `nft list table inet acme_egress`; DVV:n osoitteet muuttuneet → `install-host.sh install --egress-allow ...` |
| `urn:ietf:params:acme:error:unauthorized` / `Invalid response from http://.../.well-known/acme-challenge` | HTTP-01 ei tavoita nginxiä | Testaa ulkoa `curl http://<domain>/.well-known/acme-challenge/x` (404 = nginx vastaa). Tarkista DNAT 80 → keskus:8080, firewalld 8080, `acme-nginx` healthy |
| `externalAccountRequired` / `accountDoesNotExist` | tili puuttuu (lego-data menetetty) eikä EAB ole annettu | palauta lego-data (`restore.sh lego-data`) tai rekisteröi uudelleen: `secrets.sh eab` (EAB Vaultista `secret/acme/dvv-eab`), aja EAB-ajo, `eab-remove` |
| `poistetaan rekisteröimätön ACME-tili` (varoitus) | edellinen rekisteröinti epäonnistui; korjattu automaattisesti | aja EAB-ajo uudelleen |
| `rateLimited` | liikaa tilauksia | odota; älä pakota uusintaa toistuvasti |
| `acme-deploy: ... permission denied` (Vault) | `vault_token` vanhentunut tai mitätöity | `secrets.sh vault-token --rotate` (ylläpitäjä) |
| `Vault-tokenin uusinta epäonnistui` | Vault sinetöity (R1) tai token vanhentunut | kuten yllä |

Viimeisin onnistunut ajo: healthcheck "uusinta: viimeisin onnistunut ...". Varoitus yli 36 h.

## R4. Pakotettu uusinta (sulkeminen, avaimen vaihto, PFX_COMPAT-muutos)
Kaikki `certs.conf`:n varmenteet:
```
acmesvc$ scripts/renew.sh -e RENEW_DAYS=3650
```
Yksittäinen varmenne: aja sama väliaikaisella `certs.conf`:lla, jossa on vain se rivi
(`ACME_CONF_DIR`-hakemiston kopio). Uusi versio leviää palvelimille 1,5 tunnin kuluessa;
nopeuta palvelimella `Restart-Service vault-agent; Start-ScheduledTask Cert-Install`.

## R5. Palvelutoken tai ylläpitäjätunnus
- **acme-writer / snapshot -token vanhentunut tai vuotanut:** `secrets.sh vault-token --rotate`,
  `secrets.sh snapshot-token --rotate` (vanha mitätöidään).
- **Ylläpitäjä menetti TOTP-laitteen:** toinen ylläpitäjä: `vault-init.sh admin-add <tunnus> --reset-totp`
  (asettaa myös uuden salasanan).
- **Kaikki ylläpitäjät lukittu ulos:** luo root-token avainosilla (R6), lisää ylläpitäjä
  `VAULT_ADMIN_TOKEN_FILE`-tiedostolla, mitätöi root-token (`vault-init.sh revoke-root`).

## R6. Root-tokenin luonti hätätilanteessa (generate-root)
Vaatii kynnyksen verran avainosia. Tehdään kontissa; OTP pidetään vain muistissa:
```
acmesvc$ podman exec -it acme-vault vault operator generate-root -init     # tulostaa Nonce ja OTP
acmesvc$ podman exec -it acme-vault vault operator generate-root            # kukin haltija, piilotettu syöte
acmesvc$ podman exec -it acme-vault vault operator generate-root -decode=<encoded> -otp=<OTP>
```
Kirjoita token tiedostoon (0600), käytä `VAULT_ADMIN_TOKEN_FILE=...` ja mitätöi heti:
`VAULT_ADMIN_TOKEN_FILE=... scripts/vault-init.sh revoke-root`, `shred -u` tiedosto.

## R7. Avainosan haltija vaihtuu tai osa on kadonnut (rekey)
Kun kynnys on vielä saavutettavissa, vaihda kaikki osat uusiin:
```
acmesvc$ podman exec -it acme-vault vault operator rekey -init -key-shares=5 -key-threshold=3 \
           [-pgp-keys=...]       # PGP-avaimet konttiin kuten vault-init.sh tekee
acmesvc$ podman exec -it acme-vault vault operator rekey     # kukin nykyinen haltija
```
Uudet osat näytetään kerran. Ota varmuuskopio heti (`backup.sh`); vanhat snapshotit vaativat
vanhat osat. **Jos kynnys ei ole enää saavutettavissa, Vaultin dataa ei voi avata:** palvelimille
asennetut varmenteet toimivat vanhenemiseensa asti; rakenna Vault uudelleen (vault-init.sh init),
liitä palvelimet uudelleen ja aja pakotettu uusinta.

## R8. Varmuuskopio epäonnistuu
| Oire | Korjaus |
|---|---|
| "snapshot_token puuttuu" / `permission denied` | `secrets.sh snapshot-token --rotate` |
| "Vault on sinetöity" | R1 |
| levytila (healthcheck "levytila") | siivoa tai pienennä `RETENTION_DAYS`; siirrä vanhat ulos |
| gpg-virhe | tarkista `BACKUP_GPG_KEYFILE` (julkinen avain, luettavissa acmesvc:lle) |
Tila: `systemctl --user status vault-snapshot.service`.

## R9. Täydellinen palautus (keskus tuhoutunut)
1. Uusi RHEL 9 -isäntä samalla IP:llä ja DNS-nimellä (agenttien CIDR-sidonta ja TLS-nimi).
2. `import-release.sh` (sama versio kuin varmuuskopiossa), `install-host.sh install ...`.
3. `restore.sh config <kopio> --to /tmp/conf` → kopioi `.env`, `certs.conf`, `tls/ca.pem`, `tls/vault.crt`
   rootina `/etc/acme-podman`:iin. Vaultin TLS-avain: luo uusi (`tls-init.sh generate --renew`, vaatii
   CA-avaimen offline-säilöstä) – `ca.pem` pysyy samana, joten agentteja ei tarvitse muuttaa.
4. `acme-compose.sh up -d`, `restore.sh vault <kopio>`, `vault-unseal.sh` alkuperäisillä osilla.
5. `restore.sh lego-data <kopio>`, `secrets.sh vault-token --rotate`, `secrets.sh snapshot-token --rotate`.
6. `install-host.sh enable-services`, `healthcheck.sh`, `egress-check.sh`, `backup.sh`.
Harjoiteltu automaattisesti kehitysympäristössä (e2e "palautustesti").

## R10. Keskuksen tai Vaultin vaarantuminen
1. Eristä keskus verkosta (paitsi ylläpito), säilytä lokit (`collect-diagnostics.sh`, audit-loki).
2. Pyydä DVV:ltä kaikkien varmenteiden sulkeminen ja tarvittaessa uudet EAB-tunnisteet.
3. Rakenna keskus puhtaana (uudet avainosat, uusi Vaultin CA, uusi ACME-tili), liitä kaikki
   palvelimet uudelleen (uusi `ca.pem`, `onboard-server.sh csv` + asennus).
4. Palvelimen vaarantuminen: [windows-liittaminen.md](windows-liittaminen.md#9-tietoturvahuomiot).

## R11. Audit-laite estää Vaultin
Vault kieltäytyy pyynnöistä, jos se ei voi kirjoittaa audit-lokia (`audit: ... failed`).
Syy yleensä täysi levy: `df -h ~acmesvc`, `podman exec acme-vault du -sh /vault/logs`. Vapauta tilaa
(`vault-audit-rotate.sh`, pienennä `AUDIT_KEEP_DAYS`).

## R12. Ulosmenon tarkistus (egress-check) näyttää VIKA
| Rivi | Korjaus |
|---|---|
| `lego -> https://1.1.1.1/: kohde tavoitettiin` | nftables-sääntö puuttuu: `systemctl status acme-egress-nft`, `install-host.sh check` |
| `DVV ei vastaa` | `--egress-allow`-osoitteet, DNS (`dig <DVV:n nimi>`), välityspalvelin (`HTTPS_PROXY`) |
| `DVV tavoitettiin, mutta curl palautti 60` | luottamusketju: `ca-certificates` lego-imagessa vanha → uusi julkaisu; TLS-tarkastava välityspalvelin ei ole sallittu |
| `tarkistus ei ajautunut (podman 125)` | kontti ei käynnissä tai image puuttuu (`podman images`) |

## R13. Aika
Poikkeama > 60 s rikkoo TOTP-kirjautumisen (tarkistus ±30 s) ja voi rikkoa ACME:n ja agentit.
`chronyc tracking`; sisäinen NTP `install-host`:n ulkopuolella (chrony.conf).
