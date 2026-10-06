# Keskuspalvelin rootless Podmanilla: asennus ja käyttö

Keskuspalvelin (RHEL 9) ajaa kolmea konttia palvelukäyttäjänä `acmesvc` (rootless podman):

| Kontti | Image | Verkko | Tehtävä |
|---|---|---|---|
| `acme-nginx` | nginx-unprivileged | `edge` (internal, ei reittiä ulos) | HTTP-01-haasteet :8080 (palomuuri DNAT 80 → 8080), muu → 301 https |
| `acme-vault` | hashicorp/vault | isännän verkko, kuuntelee vain `VAULT_BIND_IP:8200` | varmenteiden jakelu agenteille (raft, TLS) |
| lego (kertakontti) | oma `acme-lego` | isännän verkko | ACME-uusinta DVV:ltä kahdesti päivässä, vienti Vaultiin |

Vault ja lego ovat isännän verkossa, jotta Vault näkee agenttien todellisen IP:n (AppRole-tunnisteet
on sidottu palvelimen IP:hen). Niiden ulosmenevä liikenne rajataan isännän nftables-säännöllä
palvelukäyttäjän uid:n perusteella: sallittu vain DVV (tai välityspalvelin) ja sisäinen DNS.
Verkkoyhteydet: [verkko.md](verkko.md). Häiriöt: [runbook.md](runbook.md).
Julkaisupaketti ja päivitykset ilmaraossa: [paivitys-ilmarako.md](paivitys-ilmarako.md).

## Hakemistot ja tiedostot

| Polku | Omistaja | Sisältö |
|---|---|---|
| `/opt/acme/releases/<versio>/` | root, vain luku | julkaisupaketti (`podman/`, `windows/`, `linux/`, `docs/`) |
| `/opt/acme/current` → `releases/<versio>` | root | käytössä oleva julkaisu |
| `/etc/acme-podman/.env` | root:acmesvc 0640 | asetukset, **ei salaisuuksia** (pohja `podman/.env.example`) |
| `/etc/acme-podman/certs.conf` | root 0644 | varmennelista (`nimi domain[,domain]`) |
| `/etc/acme-podman/tls/` | acmesvc | `ca.pem` (jaetaan agenteille), `vault.crt`, `private/ca.key` (siirrä offline-säilöön) |
| `/srv/acme-backup/` | acmesvc 0700 | varmuuskopiot (`BACKUP_DIR`) |
| `~acmesvc` = `/var/lib/acmesvc` | acmesvc 0700 | podmanin tallennus, volyymit, salaisuudet, käyttäjän systemd-yksiköt |

**Salaisuudet** ovat vain podman secreteinä (`podman secret ls`): `vault_tls_key`, `vault_token`
(acme-writer), `snapshot_token`, ja vain ensimmäisessä rekisteröinnissä `lego_eab_kid`/`lego_eab_hmac`.
Podmanin oletustallennus on tiedosto palvelukäyttäjän kotihakemistossa (0700); levysalaus on suositeltava.

## Komennot palvelukäyttäjänä

Palvelukäyttäjällä ei ole kirjautumiskuorta. Ylläpitäjä avaa kuoren näin:
```
sudo -u acmesvc -H env XDG_RUNTIME_DIR=/run/user/$(id -u acmesvc) \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u acmesvc)/bus bash
cd /opt/acme/current/podman
```
Tässä dokumentissa `acmesvc$` tarkoittaa tätä kuorta ja `root#` pääkäyttäjää. Yksittäiset
systemd-komennot rootina: `systemctl --user -M acmesvc@ status acme-stack`.

## 1. Asennus alusta loppuun

### 1.1 Julkaisupaketti
Tuo allekirjoitettu paketti ilmarakoon ja tarkista se ennen mitään muuta ([paivitys-ilmarako.md](paivitys-ilmarako.md)):
```
root# /mnt/media/release-<versio>/podman/scripts/import-release.sh /mnt/media/release-<versio>
```
Skripti tarkistaa allekirjoituksen ja tarkistussummat, purkaa paketin `/opt/acme/releases/<versio>`:iin,
lataa imaget palvelukäyttäjälle ja asettaa `/opt/acme/current`-linkin.

### 1.2 Isännän valmistelu
```
root# /opt/acme/current/podman/scripts/install-host.sh install \
        --server-cidrs 10.1.0.0/16,10.2.0.0/16 --vault-ip 10.0.0.10 \
        --egress-allow <DVV:n ACME-osoite>:443[,<CRL>:80] --dns 10.0.0.53,10.0.0.54 \
        [--skip-packages] [--dry-run]
root# /opt/acme/current/podman/scripts/install-host.sh check
```
Tekee: paketit (podman, podman-compose EPEListä tai sisäisestä varastosta, nftables, firewalld),
käyttäjän `acmesvc` (subuid/subgid, linger), hakemistot ja SELinux-kontekstit (`container_ro_file_t`),
firewalld-säännöt (8080 kaikille, 8200 vain palvelinverkoista Vaultin IP:hen), egress-rajauksen
(`/etc/nftables/acme-egress.nft`, `acme-egress-nft.service`) ja käyttäjän systemd-yksiköt.
Uudelleenajo on turvallinen. SELinux pysyy Enforcing-tilassa.

### 1.3 Asetukset
Täytä `/etc/acme-podman/.env` (kaikki `<...>`-arvot) ja `certs.conf`:
```
VAULT_BIND_IP=10.0.0.10
VAULT_API_ADDR=https://vault.asiakas.fi:8200
LEGO_SERVER=https://<DVV:n ACME directory -URL>
LEGO_EMAIL=varmenteet@asiakas.fi
KEY_TYPE=RSA2048
PFX_COMPAT=modern        # legacy, jos IIS-palvelimissa on Server 2016
BACKUP_GPG_KEYFILE=/etc/acme-podman/backup-pub.asc   # suositus
```
Imagejen digestit ovat valmiina julkaisun `.env.example`:ssä (import-release.sh päivittää `LEGO_IMAGE`:n).

### 1.4 Vaultin TLS
Sisäinen CA ja palvelinvarmenne (SAN: DNS-nimi, sisä-IP, `vault`, `127.0.0.1`):
```
acmesvc$ scripts/tls-init.sh generate --dir /etc/acme-podman/tls --dns vault.asiakas.fi --ip 10.0.0.10
```
Tai asiakkaan PKI:stä: `tls-init.sh import --dir ... --cert server.pem --key server.key --ca ca.pem`.
Palvelimen avain menee suoraan podman secretiksi `vault_tls_key`. **Siirrä `tls/private/ca.key`
offline-säilöön** (tarvitaan vain palvelinvarmenteen uusintaan, ks. runbook). Jaa `tls/ca.pem` agenteille.

### 1.5 Käynnistys ja Vaultin alustus
```
acmesvc$ printf placeholder | podman secret create vault_token -     # korvataan alustuksessa
acmesvc$ scripts/acme-compose.sh up -d
acmesvc$ scripts/vault-init.sh init --shares 5 --threshold 3 \
           [--pgp-keys a.asc,b.asc,c.asc,d.asc,e.asc --root-pgp-key root.asc --out /tmp/avainosat.json]
```
`init` tekee: `operator init` → avaus → asetukset (KV v2 `secret/` max 10 versiota, AppRole, userpass,
file-audit `/vault/logs/audit.log`, policyt `acme-writer`, `acme-admin`, `onboard-admin`, `snapshot`,
`vault-admin`, token-roolit, TOTP-MFA ylläpitäjille) → ensimmäinen ylläpitäjä (salasana + TOTP-URL
todennussovellukseen) → palvelutokenit podman secreteiksi → ylläpitäjän kirjautumisen todennus →
**root-token mitätöidään**.

- **Ilman PGP:tä** avainosat näytetään kerran päätteellä (ei levylle). Kirjaa kukin osa eri haltijalle.
- **PGP:llä** kukin osa salataan haltijan julkisella avaimella ja tallennetaan `--out`-tiedostoon;
  toimita osat haltijoille ja poista tiedosto. Haltija purkaa omansa: `base64 -d | gpg -d`.

Lisää ylläpitäjiä: `acmesvc$ scripts/vault-init.sh admin-add etunimi.sukunimi` (vaatii kirjautumisen).

### 1.6 ACME-tilin rekisteröinti (EAB, kerran)
```
acmesvc$ scripts/secrets.sh eab                    # DVV:n KID ja HMAC piilotettuna
acmesvc$ ACME_COMPOSE_FILES=compose.eab.yaml scripts/acme-compose.sh --profile jobs run --rm -T lego
acmesvc$ journalctl --user -t acme-renew -t acme-deploy -n 30
acmesvc$ scripts/secrets.sh eab-to-vault           # EAB talteen Vaultiin secret/acme/dvv-eab
acmesvc$ scripts/secrets.sh lego-account-to-vault  # ACME-tili talteen secret/acme/lego-account
acmesvc$ scripts/secrets.sh eab-remove             # EAB pois keskuksesta
```
Normaalit ajot käyttävät vain `compose.yaml`:ia, jossa EAB-salaisuuksia ei ole.

### 1.7 Palveluiden käyttöönotto ja tarkistus
```
root#    /opt/acme/current/podman/scripts/install-host.sh enable-services
acmesvc$ scripts/healthcheck.sh
acmesvc$ scripts/egress-check.sh       # DVV vastaa, muu ulosmeno estetty
acmesvc$ scripts/backup.sh             # ensimmäinen varmuuskopio heti
```

## 2. Päivittäinen käyttö

| Tehtävä | Komento |
|---|---|
| Tila (valvonta, 0/1/2) | `acmesvc$ scripts/healthcheck.sh [--quiet]` |
| Konttien tila | `acmesvc$ scripts/acme-compose.sh ps` |
| Palvelut ja ajastimet | `acmesvc$ systemctl --user status acme-stack; systemctl --user list-timers` |
| Uusinnan lokit | `acmesvc$ journalctl --user -t acme-renew -t acme-deploy --since -2d` |
| nginx / Vault -lokit | `journalctl --user -t acme-nginx` / `-t acme-vault` |
| Vaultin audit-loki | `acmesvc$ podman exec acme-vault tail /vault/logs/audit.log` (kierto päivittäin, `AUDIT_KEEP_DAYS`) |
| Uusinta heti | `acmesvc$ systemctl --user start acme-renew.service` |
| Uusi varmenne | lisää `certs.conf`:iin (root) ja aja uusinta |
| Palvelimen liittäminen | [windows-liittaminen.md](windows-liittaminen.md), `scripts/onboard-server.sh` |

Ajastimet: `acme-renew.timer` (03:00 ja 15:00 + ≤ 1 h), `vault-snapshot.timer` (02:30),
`vault-audit-rotate.timer` (00:05).

## 3. Unseal uudelleenkäynnistyksen jälkeen

Vault käynnistyy aina **sinetöitynä** (`healthcheck.sh`: KRIITTINEN, "SINETÖITY"). Agentit eivät saa
varmenteita, mutta asennetut varmenteet toimivat. Kynnyksen verran haltijoita syöttää osansa:
```
acmesvc$ scripts/vault-unseal.sh          # kysyy osat piilotettuna, kunnes kynnys täyttyy
acmesvc$ scripts/vault-unseal.sh --status
acmesvc$ scripts/vault-unseal.sh --reset  # jos väärä osa syötettiin
```
Haltijat voivat syöttää osansa eri istunnoista; edistyminen säilyy Vaultissa, kunnes kynnys täyttyy.
Kontti ei jää uudelleenkäynnistyssilmukkaan sinetöitynä (healthcheck "unhealthy", ei restart).

## 4. Kontti-imagejen päivitys ja palautus

Imaget on kiinnitetty digestillä `.env`:ssä; mitään ei vedetä verkosta (`pull_policy: never`).
Ei automaattisia päivityksiä (`podman auto-update` ei koske näitä).

1. Tuo uusi julkaisu rinnalle: `import-release.sh` (ei vaihda käytössä olevaa).
2. Ota varmuuskopio: `scripts/backup.sh`.
3. Vaihda yksi image kerrallaan `.env`:iin (nginx → lego → Vault viimeisenä) ja nosta:
   `scripts/acme-compose.sh up -d nginx` → `healthcheck.sh`.
   Lego: `scripts/acme-compose.sh --profile jobs run --rm -T lego --dry-run` ja tavallinen ajo.
4. Vault viimeisenä, hallitusti: ilmoita avainosien haltijoille, `acme-compose.sh up -d vault`,
   `vault-unseal.sh`, `healthcheck.sh`, testaa agentin haku (`onboard-server.sh list`, agentin loki).
5. **Palautus:** palauta edellinen digest `.env`:iin ja `acme-compose.sh up -d <palvelu>`. Vaultin
   tietomuoto voi muuttua päivityksessä: jos vanha versio ei käynnisty uudella datalla, palauta
   ennen päivitystä otettu snapshot (kohta 5). Tarkempi kuvaus: [paivitys-ilmarako.md](paivitys-ilmarako.md).

## 5. Varmuuskopiot ja palautus

`vault-snapshot.timer` ajaa `backup.sh`:n päivittäin → `BACKUP_DIR/<UTC-aika>/`:

| Tiedosto | Sisältö | Huom. |
|---|---|---|
| `vault.snap` | raft-snapshot | salattu Vaultin avaimella: palautus vaatii avainosat |
| `lego-data.tar.gpg` | ACME-tili ja varmenteet | salattu `BACKUP_GPG_KEYFILE`:llä (ilman: `.tar`, salaamaton!) |
| `config.tar` | `/etc/acme-podman` ilman `tls/private` | |
| `SHA256SUMS` | tarkistussummat | `restore.sh` tarkistaa aina ensin |

Säilytys `RETENTION_DAYS` (oletus 30). Kopioi `BACKUP_DIR` säännöllisesti keskuspalvelimen ulkopuolelle.

**Palautus:**
```
acmesvc$ scripts/restore.sh verify /srv/acme-backup/<aika>
acmesvc$ scripts/restore.sh vault /srv/acme-backup/<aika>        # ks. alla
acmesvc$ scripts/restore.sh lego-data /srv/acme-backup/<aika>    # gpg-yksityinen avain tarvitaan
acmesvc$ scripts/restore.sh config /srv/acme-backup/<aika> --to /tmp/conf   # vertaa ja kopioi rootina
```
- **Uusi asennus (katastrofi):** asenna kohdat 1.1–1.5 *ilman* `vault-init.sh init`:iä, aja
  `restore.sh vault` alustamattomaan Vaultiin: skripti alustaa väliaikaisesti, palauttaa snapshotin,
  käynnistää Vaultin uudelleen ja pyytää avaamaan sen **alkuperäisillä** avainosilla. Tunnukset,
  policyt, palvelutokenit ja agenttien roolit palautuvat. Palvelutokenit ovat jo podman secreteinä,
  jos ne palautetaan samalle palvelukäyttäjälle; muuten `secrets.sh vault-token --rotate` ja
  `secrets.sh snapshot-token --rotate`.
- **Olemassa oleva Vault:** `restore.sh vault` korvaa datan (vahvistus `PALAUTA`, ylläpitäjä).

**Palautustesti** tehdään kehitysympäristössä automaattisesti (`tests/podman/e2e.bats`:
"palautustesti"). Tuotannossa harjoittele vähintään kerran vuodessa erillisellä koneella.

## 6. EAB-avaimet ja ACME-tili

- EAB (DVV:n KID/HMAC) tarvitaan vain tilin rekisteröintiin. Säilytä `secret/acme/dvv-eab`
  (`secrets.sh eab-to-vault`); poista keskukselta (`eab-remove`).
- ACME-tili on `acme_lego-data`-volyymissa ja varmuuskopioissa; lisäksi `secret/acme/lego-account`
  (`secrets.sh lego-account-to-vault`). Palautus volyymiin: `restore.sh lego-data` tai Vaultista:
  `vault kv get -field=archive secret/acme/lego-account | base64 -d | tar -xz` volyymin juureen.
- Lego v5 ei osaa siirtää vanhan isäntäkoneversion (`keskus/`, lego v4 `--filename`) tilaa:
  konttiversio rekisteröi tilin uudelleen EAB:llä.

## 7. Vianmääritys
Katso [runbook.md](runbook.md).
