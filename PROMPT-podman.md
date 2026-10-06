# Tehtävä: keskuspalvelin ja Vault rootless Podmanilla + Windows-palvelinten liittäminen

> Käyttö: kopioi tämä tiedosto repon juureen ja käynnistä Claude Code plan-tilassa:
> "Lue PROMPT-podman.md ja tee sen mukainen suunnitelma. Älä vielä muuta tiedostoja."
> Täytä ensin kohta 1 (Lähtötiedot).

Lue ensin `CLAUDE.md`, `README.md` ja kaikki tiedostot hakemistoissa `keskus/`, `linux/`
ja `windows/`. Ne kuvaavat nykyisen, isäntäkoneelle asennettavan ratkaisun. Tehtäväsi on
siirtää **keskuspalvelin (nginx + lego) ja Vault rootless Podman -konteiksi podman composella**
ja tuottaa **kattava, testattu Windows-palvelinten liittämisprosessi** (skripti + ohje).
**Kohdeympäristö on ilmarako, jossa ainoa sallittu ulkoinen yhteys on keskuspalvelimelta
DVV:hen** (ks. kohta 11). Rakennus ja testaus tehdään ilmaraon ulkopuolella, ja tuloksena
on allekirjoitettu julkaisupaketti, joka asennetaan ilman verkkoyhteyksiä.
Palvelinten Vault Agentteja EI kontiteta. Niiden toiminta ja tarkistava asennuslogiikka
säilyvät ennallaan.

Kaikki `CLAUDE.md`:n turvallisuussäännöt ja koodikäytännöt ovat voimassa koko työn ajan.

---

## 1. Lähtötiedot (täytä)

- Keskuspalvelimen käyttöjärjestelmä: `[esim. RHEL 9.4]`, SELinux: `[enforcing]`
- Podman-versio: `[esim. 5.x]`, compose-toteutus: `[podman-compose / podman compose + docker-compose]`
- Vault vai OpenBao: `[valinta]`, versio: `[esim. 1.x.y]`
- Lego-versio: `[esim. v4.x.y]`
- Keskuspalvelimen sisäverkon IP: `[10.x.x.x]`, Vaultin DNS-nimi: `[vault.asiakas.fi]`
- Palvelinverkot, joista sallitaan Vault-yhteys (TCP 8200): `[10.1.0.0/16, ...]`
- Vaultin TLS-varmenne: `[asiakkaan sisäinen PKI / generoidaan oma sisäinen CA]`
- Unseal-avainten jako: `[esim. 5 osaa, kynnys 3]`, PGP-avaimet haltijoille: `[kyllä/ei]`
- Varmuuskopiokohde: `[esim. /srv/backup tai NFS/S3]`
- Windows-palvelimet: `[esim. Windows Server 2019 ja 2022]`, ovatko mukana 2016: `[kyllä/ei]`
- Windows-massajakelu: `[käsin / Ansible WinRM:llä / SCCM / Intune / muu]`
- Koodinallekirjoitusvarmenne PowerShell-skripteille: `[on / ei vielä]`

Ilmarako:
- Keskuksen yhteys DVV:hen: `[suora palomuurisääntö / pakotettu välityspalvelin (HTTPS_PROXY)]`
- DVV:n ACME-palvelun nimet ja osoitteet, jotka sallitaan: `[selvitetään DVV:ltä]`
- DVV:n CRL/OCSP-osoitteet sallitaan keskukselle: `[kyllä / ei]`
- Saapuva TCP 80 DVV:n validaattoreilta keskukselle (HTTP-01): `[sallittu / selvitettävä]`,
  validaattoreiden osoitteet: `[selvitetään DVV:ltä]`
- Ratkaisevatko palvelujen domainit julkisesti osoitteeseen, josta liikenne ohjautuu keskukselle: `[kyllä / ei]`
- Sisäinen konttirekisteri: `[on (osoite) / ei, imaget tar-arkistoina]`
- Sisäinen pakettivarasto (RPM, EPEL tai vastaava podman-composelle): `[on / ei]`
- Sisäinen aikalähde (NTP): `[osoite]`, sisäinen DNS: `[osoite]`
- Siirtomenettely ilmarakoon: `[esim. tarkastettu siirtomedia / siirtopalvelu]`
- Julkaisujen allekirjoitusavain: `[GPG / cosign / ei vielä]`

Jos jokin tieto puuttuu, kysy ennen toteutusta äläkä arvaa.

---

## 2. Työskentelytapa

1. **Suunnitelma ensin.** Tee kirjallinen suunnitelma: hakemistorakenne, kontit, verkot,
   volyymit, salaisuudet, systemd-yksiköt, skriptit ja testit. Listaa riskit ja avoimet
   kysymykset. Odota hyväksyntääni ennen toteutusta.
2. **Toteuta vaiheittain** (kohta 9). Jokaisen vaiheen lopuksi: aja testit ja lintterit,
   näytä tulokset, tee git-commit kuvaavalla viestillä. Älä siirry seuraavaan vaiheeseen,
   jos testit eivät mene läpi.
3. **Älä riko olemassa olevaa.** Isäntäkoneversion tiedostot (`keskus/`) jäävät paikalleen
   viitteeksi. Uusi toteutus tulee hakemistoon `podman/`. Jos muutat jaettuja skriptejä
   (esim. `lego-hook.sh`), varmista että muutos toimii molemmissa tai tee konttiversiolle oma kopio.
4. **Kerro epävarmuuksista.** Jos et ole varma jonkin työkalun parametrista tai
   käyttäytymisestä tässä versiossa, tarkista se (`--help`, dokumentaatio) ja kerro, mitä tarkistit.

---

## 3. Arkkitehtuuri

```
Internet ─:80─▶ palomuuri DNAT ─▶ isäntä :8080 ─▶ [nginx]   (verkko: edge)
                                                     │ lukee (ro)
                                              volyymi acme-webroot
                                                     │ kirjoittaa (rw)
DVV ACME ◀─HTTPS 443─ [lego, ajastettu kertakontti] (verkot: egress, vault-net)
                                                     │ TLS 8200
Palvelimet ─TCP 8200─▶ isäntä <sisä-IP>:8200 ─▶ [vault]  (verkko: vault-net)
```

Eristysvaatimukset, jotka on myös testattava:
- **nginx ei tavoita Vaultia** eikä internetiä ulospäin. Se näkee vain `acme-webroot`-volyymin vain luku -tilassa.
- **Vault ei näy internetiin.** Portti 8200 julkaistaan vain sisäverkon IP:hen, ja isännän palomuuri sallii sen vain palvelinverkoista.
- **Vain lego-kontilla** on yhteys sekä DVV:hen että Vaultiin. Se ei ole käynnissä jatkuvasti vaan ajetaan ajastettuna.

---

## 4. Hakemistorakenne (ehdotus, saat perustellusti muuttaa)

```
podman/
  compose.yaml                 # tuotanto
  compose.dev.yaml             # kehitys: Pebble-testi-ACME + Vault ilman tuotantoavaimia
  .env.example                 # ei salaisuuksia: versiot, digestit, IP:t, polut
  images/lego/Containerfile    # lego + vault CLI + bash + openssl, ei-root-käyttäjä
  images/lego/acme-renew.sh    # konttiversio keskus/acme-renew.sh:sta
  images/lego/lego-hook.sh     # konttiversio keskus/lego-hook.sh:sta
  nginx/default.conf           # :8080, /.well-known/acme-challenge/ + 301 https
  vault/vault.hcl              # raft, TLS, disable_mlock, api_addr, cluster_addr
  config/certs.conf            # varmennelista (sama muoto kuin ennen)
  systemd/                     # käyttäjän systemd-yksiköt (ks. kohta 6)
  scripts/
    install-host.sh            # isännän valmistelu (ajetaan rootina kerran)
    tls-init.sh                # Vaultin TLS: sisäinen CA tai olemassa olevan tuonti
    vault-init.sh              # init, unseal-ohje, policyt, audit, tokenit -> podman secret
    vault-unseal.sh            # avustin unsealiin (avainosat kysytään, ei tallenneta)
    secrets.sh                 # podman secretien luonti/kierrätys
    onboard-server.sh          # konttiversio: ajaa vault-komennot vault-kontissa
    backup.sh / restore.sh     # raft snapshot + lego-data + konfiguraatio
    healthcheck.sh             # tilan tarkistus valvontaa varten
  tests/                       # bats e2e -testit kehitysympäristöä vasten
windows/
  Install-WindowsAgent.ps1     # uusi: palvelimen liittäminen yhdellä komennolla
  Remove-WindowsAgent.ps1      # uusi: palvelimen poisto jakelusta
docs/
  windows-liittaminen.md       # uusi: kattava ohje (ks. kohta 8)
  keskuspalvelin-podman.md     # uusi: asennus, käyttö, unseal, päivitys, palautus
  runbook.md                   # uusi: häiriötilanteet ja niiden korjaus
```

---

## 5. Konttivaatimukset

### Yhteiset
- **Ilmarako**: tuotannossa ei koskaan vedetä imageja verkosta (`pull_policy: never`),
  vaan ne ladataan julkaisupaketista tai sisäisestä rekisteristä. Kaikki binäärit
  leivotaan imageen rakennusvaiheessa ilmaraon ulkopuolella.
- **Rootless**: kaikki kontit ajetaan erillisellä palvelukäyttäjällä (esim. `acmesvc`),
  jolle `loginctl enable-linger`. Ei rootful-podmania.
- **Imaget kiinnitetään digestillä** (`image@sha256:...`), ei `latest`-tageja. Digestit
  `.env`:iin, ja dokumentoi päivitysmenettely (digestin vaihto + testi + palautus).
- **Kovennus jokaisessa kontissa** kun mahdollista: `read_only: true`, tarvittavat
  `tmpfs`-liitokset, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`,
  ei-root käyttäjä kontin sisällä, SELinux-labelit volyymeille (`:Z` yksityisille, `:z` jaetuille).
- **Healthcheck** jokaiselle pitkäkestoiselle kontille.
- **Lokit** journaldiin (`log_driver: journald`) tunnisteella, jotta ne löytyvät `journalctl`illa.
- **Salaisuudet vain `podman secret`-mekanismilla** tiedostoina `/run/secrets/`-polussa.
  Ei salaisuuksia compose-tiedostossa, `.env`:ssä tai kontin ympäristömuuttujissa
  (`podman inspect` ei saa paljastaa niitä). Skriptit lukevat salaisuuden tiedostosta
  ajonaikaisesti prosessin omaan ympäristöön.

### nginx
- Virallinen `nginx-unprivileged`-image (tai vastaava), kuuntelee 8080, julkaistaan isännän
  porttiin 8080 (palomuuri tekee DNAT 80 → 8080, joten isäntään ei tarvita etuoikeutettua porttia).
- `acme-webroot` vain luku -tilassa. `/.well-known/acme-challenge/` tarjoillaan, kaikki muu `301 https://$host$request_uri`.
- Ei muita verkkoja kuin `edge`.

### lego (oma image)
- Monivaiheinen Containerfile: lataa lego ja vault CLI virallisista julkaisuista
  **kiinnitetyillä versioilla ja SHA256-tarkistuksella** (build arg), lopullinen image
  minimaalinen (esim. alpine tai ubi-minimal) + bash, openssl, ca-certificates, coreutils.
- Ajetaan ei-root-käyttäjänä. Entrypoint `acme-renew.sh`.
- Compose-profiili (esim. `profiles: [jobs]`), jotta `compose up` ei käynnistä sitä;
  ajo `podman compose run --rm lego`.
- Volyymit: `lego-data` (tili ja varmenteet, rw), `acme-webroot` (rw), `certs.conf` (ro).
- Salaisuudet: `vault_token`, ja vain ensimmäistä rekisteröintiä varten `lego_eab_kid` ja
  `lego_eab_hmac`. Skriptin on toimittava, kun EAB-salaisuudet on poistettu tilin luonnin jälkeen.
- `lego-hook.sh` säilyttää nykyisen toiminnan: PEM-bundle, PFX (modern/legacy), satunnainen
  PFX-salasana, kentät `fullchain`, `key`, `bundle`, `pfx_b64`, `pfx_password`, `not_after`, `domains`.
- Vault-tokenin uusinta jokaisella ajolla kuten nykyisessä `acme-renew.sh`:ssa.
- Vaultin TLS-CA luotetaan kontissa (liitetään vain luku -tilassa).
- Ulospäin vain DVV: jos käytössä on välityspalvelin, `HTTPS_PROXY` asetetaan vain
  lego-konttiin ja `NO_PROXY` kattaa Vaultin. Lego-kontin egress-verkon on oltava ainoa
  verkko, jolla on reitti ulos.

### vault
- Virallinen image valitusta tuotteesta, kiinnitetty digestillä.
- `vault.hcl`: integroitu tallennus (raft) pysyvään volyymiin `vault-data`, TLS-listener,
  `disable_mlock = true` (HashiCorpin suositus raftin kanssa), `api_addr`/`cluster_addr`,
  UI pois päältä ellei toisin päätetä.
- Portti julkaistaan **vain** `<sisä-IP>:8200:8200`.
- Audit-loki omaan volyymiinsa, ja lokikierto hoidettu.
- **Ei automaattista päivitystä eikä automaattista uudelleenkäynnistystä uuteen imageen**
  (sinetöity Vault ei palvele agentteja). `podman auto-update` ei koske tätä konttia.
- Healthcheck huomioi, että `vault status` palauttaa koodin 2 sinetöitynä: sinetöity tila
  raportoidaan selvästi eikä kontti saa jäädä uudelleenkäynnistyssilmukkaan.

---

## 6. Isäntä ja systemd

- `install-host.sh` (root, kerran, idempotentti): podman + compose, palvelukäyttäjä,
  subuid/subgid, linger, hakemistot, firewalld-säännöt (8080 kaikkialta koska DNAT,
  8200 vain palvelinverkoista), SELinux pysyy enforcing-tilassa, tarkistukset lopuksi.
- Käyttäjän systemd-yksiköt (`~/.config/systemd/user/`):
  - stack-palvelu, joka nostaa nginxin ja Vaultin koneen käynnistyessä
  - `acme-renew.timer` kahdesti päivässä `RandomizedDelaySec`illa → `podman compose run --rm lego`
  - `vault-snapshot.timer` päivittäin → raft snapshot varmuuskopiokohteeseen, säilytysaika
    parametrina; snapshot-tokenilla on vain siihen tarvittava policy
- Dokumentoi, miten palvelun tila ja lokit katsotaan (`systemctl --user`, `journalctl --user`).

---

## 7. Vaultin alustus, unseal ja ylläpito

- `tls-init.sh`: joko tuo asiakkaan PKI:n varmenteen ja avaimen tai luo sisäisen CA:n ja
  palvelinvarmenteen (SAN: DNS-nimi + sisä-IP). Tulostaa polun `ca.pem`:iin, joka jaetaan agenteille.
- `vault-init.sh` (idempotentti, tunnistaa jo alustetun Vaultin):
  - `operator init` parametreilla key-shares/threshold. Jos PGP-avaimet annettu, käytä
    `-pgp-keys` ja `-root-token-pgp-key`, jolloin avainosat tallentuvat salattuina.
    Muuten näytä avainosat **kerran** ja ohjeista niiden turvallinen talletus. Älä kirjoita
    selväkielisiä avainosia levylle.
  - KV v2 (`secret/`), AppRole, file-audit, `max-versions` polulle `secret/certs`.
  - Policyt: `acme-writer`, `acme-admin`, `snapshot`, sekä nykyisen `onboard-server.sh`:n
    tarvitsemat oikeudet ylläpitäjäroolille.
  - `acme-writer`-periodic-token suoraan podman secretiksi (ei stdoutiin).
  - Ylläpitäjien kirjautumistapa (esim. userpass + MFA tai OIDC, kysy) ja **root-tokenin
    mitätöinti** lopuksi.
- `vault-unseal.sh`: kysyy avainosat piilotetulla syötteellä, ei tallenna mitään.
- `docs/keskuspalvelin-podman.md`: asennus alusta loppuun, unseal uudelleenkäynnistyksen
  jälkeen, kontti-imagejen päivitys ja palautus, varmuuskopiot ja palautustesti,
  EAB-avainten ja legon ACME-tilin varmuuskopio Vaultiin (`secret/acme/*`).

---

## 8. Windows-palvelinten liittäminen (tärkeä osa)

### 8.1 `windows/Install-WindowsAgent.ps1`
Yksi komento liittää palvelimen jakeluun. Vaatimukset:
- Windows PowerShell 5.1 -yhteensopiva, `-WhatIf`, `-Verbose`, selkeät virheilmoitukset suomeksi.
- Parametrit: Vault-osoite, role_id, **wrapping token** (ei secret_id:tä selväkielisenä),
  varmenteiden nimet ja kunkin IIS-sidokset (`hostname:port`), polku `ca.pem`:iin ja `dvv-ca.pem`:iin.
  Tue myös parametritiedostoa (JSON) massajakelua varten.
- Esitarkistukset ennen muutoksia: OS-versio, .NET Framework ≥ 4.7.2, IIS asennettu,
  yhteys `vault:8200` (TCP + TLS `ca.pem`:llä), kellonaika (NTP-poikkeama), ylläpitäjäoikeudet,
  skriptien allekirjoitus. Jos jokin puuttuu, keskeytä ennen muutoksia ja kerro korjaus.
- vault.exe ladataan tai kopioidaan paikallisesta jakelusta, SHA256 tarkistetaan.
- Wrapping token puretaan paikallisesti. Jos purku epäonnistuu (käytetty/vanhentunut),
  keskeytä ja ilmoita mahdollisesta vuodosta. secret_id kirjoitetaan suoraan tiedostoon,
  jonka ACL on vain SYSTEM, Administrators ja `NT SERVICE\vault-agent`.
- Generoi `agent.hcl` ja `cert-install.json` parametreista.
- Luo puuttuvat IIS HTTPS -sidokset (SNI) ennen ensimmäistä asennusta.
- Aja `Setup-VaultAgent.ps1` ja odota (aikakatkaisu), että `Install-Cert.ps1` on asentanut
  jokaisen varmenteen. Todenna lopuksi TLS-yhteydellä, että IIS tarjoilee uutta varmennetta
  (thumbprint ja voimassaolo) ja raportoi tulos.
- Idempotentti: uudelleenajo päivittää konfiguraation eikä luo duplikaatteja.

### 8.2 `windows/Remove-WindowsAgent.ps1`
Palvelimen poisto jakelusta: palvelun ja ajastetun tehtävän poisto, tunnistetiedostojen
turvallinen poisto. Tulostaa ylläpitäjälle Vault-puolen komennot (secret_id:n hävitys,
roolin ja policyn poisto). Varmenteita ja IIS-sidoksia ei poisteta oletuksena (parametri).

### 8.3 Ylläpitäjän puoli
Konttiversio `podman/scripts/onboard-server.sh`:sta, joka ajaa Vault-komennot vault-kontin
kautta ja tulostaa role_id:n ja wrapping tokenin. Lisää tuki massaliittämiselle
CSV-tiedostosta (palvelin, IP, varmenteet), jolloin tuloksena on jokaiselle palvelimelle
oma parametritiedosto ilman selväkielisiä salaisuuksia.

### 8.4 `docs/windows-liittaminen.md`
Kattava ohje, jonka ylläpitäjä pystyy seuraamaan ilman muuta dokumentaatiota:
1. **Edellytykset**: Windows-versiot, .NET, IIS, PowerShell 5.1, koodinallekirjoitus,
   palomuuriavaukset (palvelin → Vault TCP 8200; DVV:n CRL/OCSP jos online-sulkutarkistus),
   DNS, NTP, tarvittavat tiedostot (`ca.pem`, `dvv-ca.pem`).
2. **Ennen liittämistä**: varmenteen lisäys `certs.conf`:iin, ensimmäinen myöntö ja
   tarkistus että se on Vaultissa, PFX-yhteensopivuus (`PFX_COMPAT=legacy` jos Server 2016).
3. **Liittäminen vaihe vaiheelta** yhdelle palvelimelle: onboarding ylläpitäjänä,
   wrapping tokenin toimitus (15 min aikaraja), `Install-WindowsAgent.ps1`, tarkistus.
4. **Massaliittäminen**: valitun jakelutavan mukainen ohje (kohta 1), mukaan lukien
   esimerkki (esim. Ansible-playbook WinRM:llä, jos valittu).
5. **Todentaminen**: palvelun tila, Application-lokin `cert-install`-tapahtumat,
   `netsh http show sslcert`, TLS-testi ulkopuolelta.
6. **Normaali elinkaari**: mitä uusinnassa tapahtuu ja milloin, secret_id:n kierrätys
   (90 pv) askel askeleelta, Vault Agentin päivitys.
7. **Vianmääritys**: taulukko oire → syy → korjaus. Vähintään: Vault sinetöity,
   CIDR-sidonta ei täsmää, wrapping token jo käytetty tai vanhentunut, TLS/CA-virhe,
   kellon poikkeama, ketju ei päädy DVV:n juureen, sulkutarkistus epäonnistuu (ei yhteyttä CRL:ään),
   PFX ei aukea (legacy/modern), IIS-sidos puuttuu, skriptin allekirjoitus puuttuu,
   varmenne asentunut mutta IIS tarjoilee vanhaa.
8. **Palvelimen poisto** jakelusta.
9. **Tietoturvahuomiot**: mitä palvelimella on levyllä, kuka voi lukea mitä, mitä
   tapahtuu jos palvelin murretaan ja miten se suljetaan pois (secret_id:n hävitys).

---

## 9. Toteutusvaiheet

1. **Suunnitelma** (kohta 2) → hyväksyntä.
2. **Imaget ja compose**: Containerfile, `compose.yaml`, nginx- ja vault-konfiguraatiot,
   `.env.example`. Testit: `podman compose config`, hadolint, yamllint, image builds.
3. **Kehitysympäristö ja e2e-testi**: `compose.dev.yaml`, jossa Pebble (ACME-testipalvelin,
   EAB päällä) ja sen haastepalvelin, sekä Vault ilman tuotantoavaimia. bats-testi, joka:
   tilaa varmenteen HTTP-01:llä nginxin kautta, varmistaa kentät Vaultissa (myös PFX aukeaa
   salasanalla), ajaa uusinnan, ja ajaa Linux-testikontissa nykyisen `install-cert.sh`:n
   Vaultista haetulla bundlella (Pebblen CA luotettuna). Testaa myös eristys:
   nginx-kontista Vault ei vastaa.
4. **Isäntä ja systemd**: `install-host.sh`, käyttäjän systemd-yksiköt, ajastimet.
   Testaa mitä voit; kerro, mitä vaatii oikean RHEL-isännän.
5. **Vaultin alustus ja ylläpito**: `tls-init.sh`, `vault-init.sh`, `vault-unseal.sh`,
   `secrets.sh`, `backup.sh`/`restore.sh` + palautustesti dev-ympäristössä.
6. **Windows-liittäminen**: kohdan 8 skriptit ja ohje. Pester-testit (mock-komennot
   netsh:lle, Vaultille ja varmennesäilölle) ja PSScriptAnalyzer.
7. **Dokumentaatio**: `docs/`-ohjeet, `runbook.md`, README:n ja CLAUDE.md:n päivitys
   kuvaamaan konttiversiota.
8. **Ilmaraon julkaisupaketti**: kohdan 11.3 mukainen `release/`-rakennus, allekirjoitus,
   tarkistus ja offline-asennuksen testi verkottomassa ympäristössä (esim. kontti tai VM
   ilman verkkoa, `--network none`).
9. **Tietoturvakatselmointi**: käy kaikki läpi CLAUDE.md:n sääntöjä ja kohdan 3
   eristysvaatimuksia vasten. Etsi erityisesti salaisuudet `podman inspect`issä,
   lokeissa ja komentoriveillä, liian laajat oikeudet, kilpailutilanteet ja ei-idempotentit kohdat.
   Korjaa ja raportoi.

---

## 10. Valmiin määritelmä

- [ ] `podman compose up` nostaa nginxin ja Vaultin rootless-tilassa, molemmat healthy
- [ ] lego ajetaan ajastettuna kertakonttina, ja e2e-testi Pebbleä vasten menee läpi
- [ ] Eristys todennettu testillä: nginx ↛ Vault, Vault ei julkaistu muuhun kuin sisä-IP:hen
- [ ] Mikään salaisuus ei näy `podman inspect`issä, compose-tiedostoissa, `.env`:ssä tai lokeissa
- [ ] Kaikki imaget kiinnitetty digestillä, binäärit tarkistussummilla
- [ ] Vault-alustus, unseal, varmuuskopio ja palautus dokumentoitu ja palautus testattu
- [ ] Windows-liittäminen yhdellä komennolla, esitarkistuksineen, idempotentti, poisto-skripti mukana
- [ ] `docs/windows-liittaminen.md` kattaa kaikki kohdan 8.4 osiot
- [ ] shellcheck, hadolint, yamllint, PSScriptAnalyzer puhtaita; bats- ja Pester-testit läpi
- [ ] Julkaisupaketti asentuu ja käynnistyy ilman verkkoyhteyttä; imaget ja paketti allekirjoitettu ja allekirjoitus tarkistetaan ennen latausta
- [ ] Ainoa ulkoinen yhteys tuotannossa on lego → DVV; muu ulospäin suuntautuva liikenne estetty ja testattu
- [ ] Sulkulistatarkistus toimii ilman palvelinten internet-yhteyttä (kohta 11.4)
- [ ] README ja CLAUDE.md päivitetty; luettelo asioista, jotka on vielä testattava oikeassa ympäristössä

---

## 11. Ilmarako

Kohdeympäristössä keskuspalvelimella on **vain** yhteys DVV:hen. Palvelimilla ja Vaultilla
ei ole mitään yhteyttä ulos. Ota tämä huomioon kaikessa, ja merkitse suunnitelmaan
selvästi jokainen kohta, joka olettaa verkkoyhteyttä.

### 11.1 Verkkoyhteydet tuotannossa (tarkka lista, dokumentoi `docs/verkko.md`:hen)
| Lähde | Kohde | Portti | Huom. |
|---|---|---|---|
| lego-kontti | DVV ACME (+ CRL/OCSP jos sallittu) | 443 / 80 | ainoa ulospäin, mieluiten allowlist-välityspalvelimen kautta |
| DVV:n validaattorit | palomuuri → keskus :8080 | 80 | HTTP-01; rajaa validaattoreiden osoitteisiin jos DVV ne kertoo |
| palvelimet | Vault | 8200 | sisäverkko |
| keskus | sisäinen NTP, DNS | 123 / 53 | |

Rakenna `scripts/egress-check.sh`, joka todentaa keskuspalvelimella, että lego-kontista
DVV vastaa ja että muut kohteet (esim. yleinen internet, imagerekisterit) EIVÄT vastaa,
ja että nginx- ja Vault-konteilla ei ole yhteyttä ulos.

**Ratkaistava ennen toteutusta:** HTTP-01 edellyttää, että palvelujen domainit
ratkeavat julkisesti osoitteeseen, josta portti 80 ohjautuu keskukselle. Jos palvelut
ovat vain sisäisiä, HTTP-01 ei toimi. Kysy minulta, ja jos vastaus on "ei", tee
suunnitelmaan DNS-01-vaihtoehto (edellyttää DVV:n tukea ja julkisen DNS:n API:a
sallittuna kohteena) äläkä toteuta HTTP-01:tä sokkona.

### 11.2 Riippuvuudet ja toimitusketju
- Inventoi kaikki ulkoiset riippuvuudet (imaget, binäärit, OS-paketit, Python-paketit
  podman-composelle, PowerShell-moduulit testaukseen) tiedostoon `release/DEPENDENCIES.md`
  versioineen, lähteineen ja tarkistussummineen.
- Imaget rakennetaan ja haetaan ilmaraon ulkopuolella, kiinnitetään digestillä ja
  viedään OCI-arkistoiksi (`podman save --format oci-archive`). Tee SBOM (esim. syft)
  ja haavoittuvuusskannaus (esim. trivy tai grype) jokaisesta imagesta; raportit pakettiin.
- Jos asiakkaalla ei ole pakettivarastoa podman-composelle, sisällytä pakettiin tarvittavat
  RPM:t/wheelit tai dokumentoi vaihtoehto (esim. `podman compose` + valmiiksi tuotu provider).
- Windows: `vault.exe` sisällytetään pakettiin tarkistussummineen; asennusskripti lukee sen
  paikallisesta polusta tai sisäiseltä jaolta, ei koskaan internetistä.

### 11.3 Julkaisupaketti
Tee `scripts/build-release.sh` (ajetaan ilmaraon ulkopuolella), joka tuottaa:
```
release/<versio>/
  images/*.oci.tar         # kaikki imaget
  bin/                     # vault.exe (Windows), muut tarvittavat binäärit
  podman/ windows/ linux/ docs/
  SHA256SUMS + SHA256SUMS.sig
  sbom/ scan/              # SBOMit ja skannausraportit
  DEPENDENCIES.md, CHANGELOG.md
```
- Allekirjoita `SHA256SUMS` valitulla avaimella. Ilmaraon puolella `scripts/import-release.sh`
  tarkistaa allekirjoituksen ja kaikki tarkistussummat ENNEN kuin mitään ladataan, ja
  lataa imaget (`podman load`) tai vie ne sisäiseen rekisteriin.
- Jos käytössä on sisäinen rekisteri ja kuvien allekirjoitus, konfiguroi
  `containers-policy.json` vaatimaan allekirjoitus näiltä imageilta.
- Päivitysmenettely: uusi julkaisu rinnalle, tuonti, kontti kerrallaan vaihto,
  terveystarkistus, palautus edelliseen julkaisuun. Vault vaihdetaan viimeisenä ja unseal
  tehdään hallitusti. Dokumentoi `docs/paivitys-ilmarako.md`:hen.

### 11.4 Sulkulistatarkistus ilman palvelinten internet-yhteyttä
Nykyinen `Install-Cert.ps1` käyttää `RevocationMode = 'Online'`, joka epäonnistuu
ilmaraossa. Toteuta:
- `cert-install.json`/`cert-install.conf`: asetus `RevocationMode` = `Offline` | `NoCheck`.
- Jos DVV:n CRL-osoitteet sallitaan keskukselle: lego-kontin ajossa (tai omana ajastettuna
  kertakonttina) haetaan DVV:n CRL:t, tarkistetaan niiden allekirjoitus DVV:n CA:lla ja
  tallennetaan Vaultiin (`secret/pki/dvv-crl`). Palvelinten agentit hakevat CRL:n samalla
  tavalla kuin varmenteet, ja asennusskriptit tarkistavat sulkutilan paikallisesta CRL:stä
  (Linux: `openssl verify -crl_check -CRLfile`; Windows: CRL tuodaan koneen säilöön ja
  `RevocationMode = 'Offline'`). Vanhentunut CRL raportoidaan, mutta se ei saa estää
  muuten kelvollisen varmenteen uusintaa (kirjaa varoitus ja tee päätös parametroitavaksi).
- Jos CRL:iä ei sallita: `NoCheck` ja dokumentoi riski ja korvaava kontrolli
  (varmenteen sulkeminen DVV:ssä + uuden varmenteen pakotettu jakelu).

### 11.5 Muut ilmaraon vaatimukset
- **Aika**: kaikki komponentit sisäisestä NTP:stä; esitarkistukset (Linux ja Windows)
  varoittavat yli 60 s poikkeamasta.
- **DNS**: keskus tarvitsee DVV:n nimet; jos välityspalvelinta ei käytetä, dokumentoi
  sisäisen DNS:n edelleenohjaus vain näille nimille. Älä kovakoodaa IP-osoitteita.
- **Testit**: Pebble ja muut testityökalut ovat vain rakennusympäristössä, ei
  julkaisupaketissa. Tee ilmaraon puolelle `scripts/smoke-test.sh`, joka toimii täysin
  offline (konttien tila, Vault unsealed, nginx vastaa haastepolkuun, viimeisin
  onnistunut uusinta, varmenteiden `not_after` Vaultissa).
- **Diagnostiikka**: koska tukihenkilö ei välttämättä pääse ympäristöön, tee
  `scripts/collect-diagnostics.sh`, joka kerää lokit ja tilatiedot yhteen arkistoon
  **ilman salaisuuksia** (tarkista ja testaa tämä), jotta ne voidaan tuoda ulos tarkasteltaviksi.
