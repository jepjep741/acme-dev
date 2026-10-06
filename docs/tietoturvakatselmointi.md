# Tietoturvakatselmointi (vaihe 9)

Katselmoitu: konttiversio (`podman/`), palvelinskriptit (`linux/`, `windows/`), julkaisuketju.
Peruste: CLAUDE.md:n turvallisuussäännöt ja PROMPT-podman.md:n eristysvaatimukset (kohta 3)
sekä ilmarako (kohta 11). Erityisesti: salaisuudet `podman inspect`issä, lokeissa ja
komentoriveillä, liian laajat oikeudet, kilpailutilanteet ja ei-idempotentit kohdat.

## Yhteenveto

| # | Havainto | Vakavuus | Tila |
|---|---|---|---|
| K1 | Egress-rajaus ei koskenut isännän verkossa ajettavia kontteja (lego, Vault) | **Kriittinen** | Korjattu, testattu |
| K2 | Julkaisun tuonnissa TOCTOU: tarkistus medialta, käyttö kopiosta | Korkea | Korjattu |
| K3 | Root-token kirjoitettiin alustuksessa hetkeksi `/tmp`:hen | Keskitaso | Korjattu |
| K4 | Uusinta ja varmuuskopio saattoivat ajautua yhtä aikaa (lego-data) | Keskitaso | Korjattu, testattu |
| K5 | Tuonnin keskeytyksen jälkeinen `.tmp` sotki uudelleenajon (ei idempotentti) | Matala | Korjattu |
| A1 | AppRole-CIDR-sidonta ei olisi toiminut rootless-portinohjauksen takia | Korkea | Korjattu vaiheessa 6 (isännän verkko) |
| A2 | Eristystestit hyväksyivät podman-virheen (125) "estetyksi" | Korkea (testi) | Korjattu vaiheessa 4 |
| A3 | `edge`-verkon DNS (aardvark) mahdollinen vuotokanava nginxistä | Matala | Korjattu vaiheessa 8 |
| A4 | Testi tulosti tokenin `podman run`:lla → journald | Matala (testi) | Korjattu vaiheessa 3; sääntö CLAUDE.md:ssä |
| A5 | `keskus/`: `UMask=0077` → haastetiedostot 0600, nginx ei lue (HTTP-01 epäonnistuu) | Toiminnallinen | Korjattu konttiversiossa; `keskus/` ennallaan (viite) |
| A6 | Alkuperäisistä .ps1-tiedostoista puuttui BOM (PS 5.1: ä/ö väärin) | Matala | Korjattu vaiheessa 6 |
| A7 | `Install-Cert.ps1` poisti kaikki saman Subjectin varmenteet; jo asennetun varmenteen sidosta ei korjattu | Keskitaso | Korjattu vaiheessa 6 |

## Korjatut havainnot

### K1 Egress-rajaus ei koskenut isännän verkon kontteja (kriittinen)
**Havainto:** nftables-sääntö rajasi paketit ehdolla `meta skuid <acmesvc>`. Bridge-verkon kontit
(nginx) lähettävät liikenteen pastan kautta, jonka omistaa `acmesvc`, joten ne rajautuivat.
Isännän verkossa ajettavien konttien (Vault, lego) socketit omistaa kuitenkin kontin käyttäjä
isännän näkökulmasta, eli **palvelukäyttäjän subuid-alueen uid** (todettu: Vault uid 100 → 100099).
Ne ohittivat rajauksen kokonaan: lego ja Vault olisivat päässeet mihin tahansa.
Vaatimuksen "vain lego-kontilla on yhteys DVV:hen" ja "muu ulospäin suuntautuva liikenne estetty" kannalta
tämä oli kriittinen. Vanha testi ajoi curlin `acmesvc`-käyttäjänä, ei kontin uid:llä, joten se ei havainnut puutetta.

**Korjaus:** `install-host.sh` lukee palvelukäyttäjän subuid-alueen `/etc/subuid`:sta ja sääntö on
`meta skuid { <uid>, <subuid-alku>-<loppu> } jump svc_out`.
**Testi:** `host.bats`: käyttäjä uid 100099 (kuten isännän verkon Vault) rajautuu (sallittu kohde
vastaa, muu estetty), alueen ulkopuolinen uid ja root eivät rajaudu.
**Oikea ympäristö:** `egress-check.sh` todentaa legon ja Vaultin rajauksen oikeilla konteilla.

### K2 Julkaisun tuonnin TOCTOU
**Havainto:** `import-release.sh` tarkisti allekirjoituksen ja summat siirtomedialta ja kopioi
paketin vasta sen jälkeen. Median kirjoitusoikeuden haltija olisi voinut vaihtaa tiedostot välissä.
**Korjaus:** paketti kopioidaan ensin root-omisteiseen väliaikaishakemistoon
(`/opt/acme/releases/.import.*`), allekirjoitus ja summat tarkistetaan **kopiosta**, ja vasta sitten
se siirretään paikalleen. Samannimistä eri pakettia ei hyväksytä.

### K3 Root-token levyllä alustuksessa
**Havainto:** `vault-init.sh init` kirjoitti root-tokenin väliaikaistiedostoon (0600, `/tmp`) asetusten
ajaksi. Keskeytys (esim. Ctrl+C, virta) olisi voinut jättää sen levylle.
**Korjaus:** token on vain prosessin ja sen aliprosessien ympäristössä (`_ACME_ADMIN_TOKEN`),
poistetaan mitätöinnin jälkeen; ylläpitäjän kirjautumistesti ajetaan ilman sitä.

### K4 Uusinnan ja varmuuskopion kilpailutilanne
**Havainto:** `acme-renew.timer` ja `vault-snapshot.timer` (molemmat `Persistent=true`) voivat
käynnistyä samaan aikaan koneen käynnistyessä; käsin ajettu uusinta voi osua ajastetun päälle.
Varmuuskopio olisi voinut viedä keskeneräisen lego-datan.
**Korjaus:** yhteinen lukko (`lib.sh: acme_job_lock`, `flock`, `$XDG_RUNTIME_DIR/acme-jobs.lock`):
`renew.sh` (uusinta, myös `acme-renew.service`), `backup.sh` ja `restore.sh lego-data`.
**Testi:** e2e "renew.sh odottaa yhteistä lukkoa".

### K5 Tuonnin uudelleenajo keskeytyksen jälkeen
Vanha `cp -a "$SRC" "$DEST.tmp"` olisi kopioinut paketin olemassa olevan `.tmp`-hakemiston *sisään*.
Nyt käytetään `mktemp -d`:tä, keskeytyksen jäänteet siivotaan ja `trap` poistaa väliaikaisen kopion.

## Tarkistetut ja kunnossa olevat

| Alue | Tulos | Todennus |
|---|---|---|
| `podman inspect` | ei tokeneita, EAB:tä eikä TLS-avainta (nginx, vault, lego) | e2e |
| journald | ei tokeneita, PFX-salasanaa, EAB:tä, root-tokenia, yksityisiä avaimia | e2e |
| Vaultin audit-loki | ei selväkielisiä tokeneita eikä PFX-salasanaa (HMAC) | e2e |
| Komentorivit | salaisuudet stdinin (`key=-`, `password=-`, JSON) tai tiedostojen kautta; skannattu: ei `-e VAULT_TOKEN=`, ei `token=$...` | katselmointi, grep |
| Diagnostiikka | todellisten podman secret -arvojen tarkistus ennen pakkausta; kanariatesti | e2e |
| Eristys | nginx ↛ Vault (nimi, isännän IP, loopback), nginx ei reittiä ulos, ei DNS:ää | e2e, offline |
| Vault | kuuntelee vain `VAULT_BIND_IP`:ssä; CIDR-sidonta toimii | e2e |
| Ylläpitäjät | TOTP pakollinen; ei pääsyä varmenteiden avaimiin; väärä TOTP/salasana hylätään | e2e |
| Julkaisu | allekirjoitus, summat, listaamattomat tiedostot, väärä avain, digest-pin ladattuna | release.bats |
| Windows | secret_id ACL ennen sisältöä; kääre vain lapsiprosessin ympäristössä; parametritiedosto ilman salaisuuksia; avain ei-vietävä; AllSigned | Pester, katselmointi |
| Idempotenssi | install-host, vault-init configure, secrets, onboard add, Install-WindowsAgent | host.bats, e2e, Pester |

## Jäännösriskit (hyväksyttävä tai päätettävä)

| # | Riski | Perustelu / korvaava kontrolli | Suositus |
|---|---|---|---|
| R1 | Isännän verkossa (Vault, lego) ei ole konttiverkon eristyskerrosta | Vaatimus: Vault näkee agenttien IP:n (CIDR-sidonta). Ulosmeno rajataan nftablesilla (K1), sisääntulo firewalldillä. Kontit voivat avata kuuntelijoita > 1024 isännän osoitteisiin; firewalld estää ulkoa. | Hyväksy; valvo `ss -ltnp` |
| R2 | Palvelukäyttäjän loopback-liikenne sallitaan (`oifname lo accept`) | Tarvitaan Vault-yhteyteen ja podmanin sisäiseen liikenteeseen. Paikalliset palvelut keskuksessa tavoitettavissa konteista. | Älä aja keskuksella muita palveluita; tiukennus porttikohtaiseksi testattava oikealla isännällä |
| R3 | Podman secretit tallentuvat salaamattomina palvelukäyttäjän kotiin (`~/.local/share/containers/storage/secrets`, 0700) | Root ja palvelukäyttäjä voivat lukea. | Levysalaus; rajoita root-pääsyä; harkitse `pass`-ajuria |
| R4 | `vault-admin`-policy voi muuttaa policyjä (myös omaansa) | Ylläpitäjät ovat luotettuja ja MFA:n takana; audit-loki kirjaa. | Rajaa ylläpitäjien määrä; tarkasta audit-loki säännöllisesti |
| R5 | `NoCheck`-sulkutarkistus ilmaraossa | Ei yhteyttä CRL:ään; korvaava kontrolli: suljetun tilalle pakotettu uusinta (runbook R4). | CRL-jakelu Vaultin kautta, kun DVV:n CRL-osoitteet tiedetään |
| R6 | Windows staging-tiedosto sisältää PFX:n ja salasanan | Luettavissa vain SYSTEM, Administrators, agentti. Asennettu avain ei-vietävä. | Hyväksy (vaatii jo ylläpitäjäoikeuden) |
| R7 | Haavoittuvuudet imageissa: lego (UBI9 openssl/pcre2/util-linux HIGH, ei korjausta), Vault (alpine libcrypto3 HIGH, korjaus saatavilla) | Raportit julkaisun `scan/`-hakemistossa. | Päivitä Vault-image, kun HashiCorp julkaisee; seuraa UBI-korjauksia |
| R8 | Ylläpitäjän token-tiedosto massajakelussa (`onboard-server.sh login`) | 0600, TTL 1 h, ohje poistaa heti. | Hyväksy; ohjeistus |
| R9 | `vault-init.sh init` -kokonaiskulku on vuorovaikutteinen (TOTP) eikä sitä testata yhtenä ajona | Osavaiheet (`init --no-configure`, `configure`, `admin-add`, `login-test`, `revoke-root`) testataan e2e:ssä. | Harjoittele kokonaiskulku testiympäristössä ennen tuotantoa |
| R10 | `collect-diagnostics.sh` ei tunnista alle 12 merkin salaisuuksia todellisen arvon perusteella | Tunnetut muodot poistetaan; podman secretit ovat pitkiä. | Tarkista arkisto ennen vientiä (ohjeistettu) |
| R11 | Käyttäjän systemd-yksiköissä ei sandboxing-direktiivejä | Rootless podman tarvitsee setuid-`newuidmap`:n (`NoNewPrivileges` rikkoisi). Kontit kovennettu (read-only, cap_drop ALL, no-new-privileges). | Hyväksy |
