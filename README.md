# DVV ACME – keskitetty varmennehallinta

Keskuspalvelin tilaa ja uusii DVV:n palvelinvarmenteet legolla ja tallentaa ne
Vaultiin (tai OpenBaoon). Palvelimet eivät tiedä ACME:sta mitään: Vault Agent
hakee niiden omat varmenteet, ja erillinen root/SYSTEM-osa asentaa ne vasta
tarkistusten jälkeen. Kuva: `dvv-acme-arkkitehtuuri.excalidraw` (avaa excalidraw.com:ssa).

> Pohjia, joita ei ole ajettu oikeaa DVV:tä tai Vaultia vasten. Testaa ensin
> yhdellä Linux- ja yhdellä Windows-palvelimella DVV:n testivarmenteella.
> Vaihda esimerkkiarvot (vault.asiakas.fi, intranet, domainit) asiakkaan omiin.

## Sisältö ja sijoitus

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

## Käyttöönottojärjestys

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

## Tarkistettavaa

- Legon versio: `--eab` ympäristömuuttujista, `--no-random-sleep`, `LEGO_SERVER` (`lego --help`).
- DVV:n tukemat avaintyypit (`KEY_TYPE` lego.env:ssä, oletus rsa2048).
- `PFX_COMPAT=legacy` jos IIS-palvelimissa on Windows Server 2016 tai vanhempi.
- Windowsilla sulkulistatarkistus vaatii yhteyden DVV:n CRL/OCSP-osoitteisiin
  (tai vaihda `RevocationMode` Install-Cert.ps1:ssä).
- Vault Agentin ajo Windows-palveluna asiakkaan Vault-versiolla.

## Tietoliikenne

| Lähde | Kohde | Portti |
|---|---|---|
| Internet (DVV:n validaattori) | palomuuri → keskus | TCP 80 |
| Keskus | DVV ACME | TCP 443 |
| Keskus | Vault | TCP 8200 |
| Palvelimet (100 kpl) | Vault | TCP 8200 (vain ulospäin) |
| Windows-palvelimet | DVV CRL/OCSP | TCP 80 (jos online-sulkutarkistus) |
