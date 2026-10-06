# DVV ACME – keskitetty varmennehallinta

Keskuspalvelin tilaa ja uusii DVV:n palvelinvarmenteet legolla ja tallentaa ne
Vaultiin. Palvelimet eivät tiedä ACME:sta mitään: Vault Agent hakee niiden omat
varmenteet, ja erillinen root/SYSTEM-osa asentaa ne vasta tarkistusten jälkeen.
Kuva: `dvv-acme-arkkitehtuuri.excalidraw` (avaa excalidraw.com:ssa).

Ratkaisusta on kaksi toteutusta:

| | Konttiversio (suositus) | Isäntäkoneversio (viite) |
|---|---|---|
| Hakemisto | `podman/` | `keskus/` |
| Keskus | rootless Podman (RHEL 9): nginx, Vault, lego kertakonttina | nginx, Vault ja lego suoraan isännälle |
| Ilmarako | allekirjoitettu julkaisupaketti, ei verkkovetoja, egress-rajaus | ei huomioitu |
| Testattu | e2e Pebbleä vasten (bats), Pester, lintterit | ei ajettu |

Palvelinten puoli (`linux/`, `windows/`) on yhteinen molemmille.

## Konttiversio

```
Internet ─:80─▶ palomuuri DNAT ─▶ isäntä :8080 ─▶ [nginx]  (edge, internal: ei reittiä ulos)
                                                    │ lukee (ro)
                                             volyymi acme-webroot
                                                    │ kirjoittaa
DVV ACME ◀─HTTPS 443── [lego, ajastettu kertakontti]   (isännän verkko, egress: vain DVV)
                                                    │ TLS
Palvelimet ─TCP 8200─▶ VAULT_BIND_IP:8200 ── [vault] (isännän verkko, kuuntelee vain sisä-IP:ssä)
```
Vault ja lego ovat isännän verkossa, jotta Vault näkee palvelinten todellisen IP:n
(AppRole-tunnisteet on sidottu palvelimen IP:hen). Niiden ulosmeno rajataan nftablesilla
palvelukäyttäjän uid:n perusteella; nginx on eristetyssä verkossa.

| Ohje | Sisältö |
|---|---|
| [docs/keskuspalvelin-podman.md](docs/keskuspalvelin-podman.md) | asennus, käyttö, unseal, imagejen päivitys, varmuuskopiot ja palautus |
| [docs/windows-liittaminen.md](docs/windows-liittaminen.md) | Windows/IIS-palvelimen liittäminen, massaliittäminen, vianmääritys |
| [docs/runbook.md](docs/runbook.md) | häiriötilanteet |
| [docs/verkko.md](docs/verkko.md) | sallitut verkkoyhteydet ja egress-rajaus |
| [docs/paivitys-ilmarako.md](docs/paivitys-ilmarako.md) | julkaisupaketti ja päivitys ilmaraossa |
| [docs/tietoturvakatselmointi.md](docs/tietoturvakatselmointi.md) | katselmoinnin havainnot, korjaukset ja jäännösriskit |

### Hakemistot

| Polku | Sisältö |
|---|---|
| `podman/compose.yaml`, `compose.eab.yaml`, `compose.dev.yaml` | tuotanto, ensimmäinen ACME-rekisteröinti, kehitys (Pebble) |
| `podman/images/lego/` | lego + vault CLI -image (UBI9-minimal), `acme-renew.sh`, `lego-hook.sh` |
| `podman/nginx/`, `podman/vault/` | nginx-konfiguraatio, `vault.hcl`, policyt |
| `podman/systemd/` | käyttäjän yksiköt (stack, uusinta, snapshot, audit-kierto) ja egress-nft |
| `podman/scripts/` | `install-host.sh`, `renew.sh`, `tls-init.sh`, `vault-init.sh`, `vault-unseal.sh`, `secrets.sh`, `onboard-server.sh`, `backup.sh`, `restore.sh`, `healthcheck.sh`, `egress-check.sh`, `acme-compose.sh` |
| `windows/` | `Install-WindowsAgent.ps1`, `Remove-WindowsAgent.ps1`, `Install-Cert.ps1`, `Setup-VaultAgent.ps1` |
| `linux/` | Vault Agent + `install-cert.sh` |
| `tests/` | `lint.sh`, `run-bats.sh` (podman/e2e, isäntä), `windows/run.sh` (Pester, PSScriptAnalyzer) |

### Testaus (rakennusympäristö, vaatii verkon)
```
tests/lint.sh                     # shellcheck, hadolint, yamllint, podman-compose config
tests/run-bats.sh                 # e2e (Pebble, Vault, lego, Linux-asiakas) + isäntätestit
tests/windows/run.sh              # PSScriptAnalyzer (PS 5.1 -profiilit) + Pester
```
Kehitysympäristö käyttää samaa podman-compose-versiota kuin RHEL 9 + EPEL (1.5.0):
`PODMAN_COMPOSE=<polku> tests/run-bats.sh`.

### Testattava oikeassa ympäristössä

Seuraavia ei voi todentaa rakennusympäristössä; ne on testattava asiakkaan RHEL-isännällä
ja Windows-palvelimilla ennen tuotantoa:

- **DVV:** ensimmäinen myöntö EAB:llä oikeaa DVV:tä vasten (avaintyyppi `KEY_TYPE`, ketju,
  mahdolliset profiilit, ARI-tuki, sulkulistaosoitteet). Pebble ei paljasta DVV:n erityispiirteitä.
- **RHEL 9 -isäntä:** SELinux Enforcing (`:z/:Z`-volyymit, `container_ro_file_t`), firewalld-säännöt,
  linger ja käyttäjän systemd-yksiköt koneen käynnistyessä, `systemctl --user -M acmesvc@`.
- **Egress:** nftables-rajaus konttiliikenteelle (pasta ja isännän verkko) `egress-check.sh`:lla;
  DVV:n osoitteet ja DNS-edelleenohjaus; välityspalvelin, jos käytössä.
- **HTTP-01 perimetristä:** DNAT 80 → 8080 ja DVV:n validaattorit; IPv6.
- **Vault:** agenttien IP-sidonta todellisista palvelinverkoista (ei NATia); unseal-käytäntö
  avainosien haltijoiden kanssa; palautusharjoitus erillisellä koneella.
- **Windows:** `Install-WindowsAgent.ps1` Server 2016/2019/2022:lla (IIS, netsh, palvelu
  virtuaalitilillä, ajastettu tehtävä, AllSigned-allekirjoitus, ACL:t), `PFX_COMPAT=legacy`
  Server 2016:lla, `Remove-WindowsAgent.ps1`. Pester-testit käyttävät mockeja Windows-komennoille.
- **Massajakelu:** Ansible-esimerkki (WinRM) asiakkaan inventaariolla.
- **Suorituskyky:** ~100 agenttia samanaikaisesti, Vaultin audit-lokin kasvu ja kierto.

## Isäntäkoneversio (keskus/, viite)

> Alkuperäinen pohja, jota ei ole ajettu oikeaa DVV:tä tai Vaultia vasten. Konttiversio korvaa sen.
> Huom: `keskus/acme-renew.service` asettaa `UMask=0077`, jolloin legon haastetiedostot ovat 0600
> eikä nginx voi lukea niitä (HTTP-01 epäonnistuu). Korjattu konttiversiossa.

### Sisältö ja sijoitus

| Tiedosto | Sijainti kohteessa | Oikeudet |
|---|---|---|
| **keskus/** | | |
| acme-renew.sh | /usr/local/sbin/ | root:root 0755 |
| lego-hook.sh | /usr/local/sbin/ | root:root 0755 |
| lego.env | /etc/acme/ | root:acme 0640 |
| vault.env | /etc/acme/ | root:acme 0640 |
| certs.conf | /etc/acme/ | root:root 0644 |
| acme-renew.service, acme-renew.timer | /etc/systemd/system/ | 0644 |
| nginx-acme.conf | /etc/nginx/conf.d/ | 0644 |
| policies.hcl | ohje Vaultin policyihin | – |
| onboard-server.sh | ylläpitäjän työasema / keskus | ajetaan ylläpitäjän Vault-tunnuksella |
| **linux/** | | |
| agent.hcl | /etc/vault-agent/ | root:vault-agent 0640 |
| vault-agent.service | /etc/systemd/system/ | 0644 |
| cert-install.path, cert-install.service | /etc/systemd/system/ | 0644 |
| install-cert.sh | /usr/local/sbin/ | root:root 0755 |
| cert-install.conf | /etc/ | root:root 0644 |
| **windows/** | | |
| agent.hcl, cert-install.json, Install-Cert.ps1 | C:\ProgramData\vault-agent\ | ACL: Setup-VaultAgent.ps1 |
| Setup-VaultAgent.ps1 | ajetaan kerran ylläpitäjänä | – |

Lisäksi tarvitaan: `ca.pem` (Vaultin TLS-CA) agenttien hakemistoon,
`dvv-ca.pem` (DVV:n juuri-CA virallisesta lähteestä) Linuxille
`/etc/cert-install/`-hakemistoon ja Windowsille `C:\ProgramData\vault-agent\`,
sekä `vault-ca.pem` keskukseen `/etc/acme/`.

### Käyttöönottojärjestys

1. **Vault**: `vault secrets enable -path=secret -version=2 kv`, `vault auth enable approle`,
   audit-loki päälle, policyt `policies.hcl`:n mukaan. Keskuksen token:
   `vault token create -policy=acme-writer -period=768h -orphan` → `vault.env`.
2. **DVV**: ACME-tili verkkoasioinnissa → directory-URL, KID ja HMAC.
   Tallenna KID/HMAC Vaultiin polkuun `secret/acme/dvv-eab` (vain ylläpito).
3. **Palomuuri**: julkisten osoitteiden TCP 80 (myös IPv6) → DNAT keskuspalvelimelle.
   Testaa: kirjoita `/var/www/acme/.well-known/acme-challenge/testi` ja hae se
   internetistä `http://<domain>/.well-known/acme-challenge/testi`.
4. **Keskus**: `useradd --system --home-dir /var/lib/lego --shell /usr/sbin/nologin acme`,
   hakemistot `/var/lib/lego` (acme 0700) ja `/var/www/acme` (acme:www-data 0750),
   nginx-konfiguraatio, `lego.env` + `vault.env` + `certs.conf`.
   Ensimmäinen ajo: `systemctl start acme-renew.service`, tarkista `journalctl -u acme-renew`.
   Kun ACME-tili on luotu: poista LEGO_EAB_KID/HMAC `lego.env`:stä ja varmuuskopioi
   `/var/lib/lego/accounts` Vaultiin. Sitten `systemctl enable --now acme-renew.timer`.
5. **Palvelin kerrallaan**: `onboard-server.sh <nimi> <ip> <varmenne...>` → role_id ja
   kääritty secret_id. Pura kääre kohteessa (`VAULT_TOKEN=<kääre> vault unwrap -field=secret_id`).
   - Linux: `useradd --system --no-create-home --shell /usr/sbin/nologin vault-agent`,
     tiedostot paikoilleen, `systemctl enable --now vault-agent cert-install.path`.
   - Windows: tiedostot paikoilleen, allekirjoita `Install-Cert.ps1`, aja `Setup-VaultAgent.ps1`.
     HTTPS-sidos IIS:ään on luotava kerran ennen ensimmäistä asennusta.
6. **Valvonta**: lokit `acme-renew`, `acme-deploy`, `cert-install` (syslog / Application-loki),
   Vaultin `not_after`-kentät ja palvelinten todellisuudessa tarjoilemat varmenteet.

### Tarkistettavaa

- Legon versio: `--eab` ympäristömuuttujista, `--no-random-sleep`, `LEGO_SERVER` (`lego --help`).
- DVV:n tukemat avaintyypit (`KEY_TYPE` lego.env:ssä, oletus rsa2048).
- `PFX_COMPAT=legacy` jos IIS-palvelimissa on Windows Server 2016 tai vanhempi.
- Windowsilla sulkulistatarkistus vaatii yhteyden DVV:n CRL/OCSP-osoitteisiin
  (tai vaihda `RevocationMode` Install-Cert.ps1:ssä).
- Vault Agentin ajo Windows-palveluna asiakkaan Vault-versiolla.

### Tietoliikenne

| Lähde | Kohde | Portti |
|---|---|---|
| Internet (DVV:n validaattori) | palomuuri → keskus | TCP 80 |
| Keskus | DVV ACME | TCP 443 |
| Keskus | Vault | TCP 8200 |
| Palvelimet (100 kpl) | Vault | TCP 8200 (vain ulospäin) |
| Windows-palvelimet | DVV CRL/OCSP | TCP 80 (jos online-sulkutarkistus) |
