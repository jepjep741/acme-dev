# Windows-palvelinten liittäminen DVV-varmennejakeluun

Tämä ohje kattaa Windows/IIS-palvelimen liittämisen keskuspalvelimen (podman) varmennejakeluun,
normaalin elinkaaren, vianmäärityksen ja poiston. Muuta dokumentaatiota ei tarvita.

**Periaate:** keskus tilaa DVV:n varmenteet ja tallentaa ne Vaultiin. Palvelimen Vault Agent
(virtuaalitili `NT SERVICE\vault-agent`) hakee vain oman palvelimensa varmenteet staging-hakemistoon,
ja SYSTEM-tehtävä `Cert-Install` asentaa ne tarkistusten jälkeen IIS:lle. Palvelin ei tiedä ACME:sta
mitään, eikä sillä ole yhteyttä internetiin.

Komennot merkitään:
- `keskus$` = keskuspalvelimella palvelukäyttäjänä (`sudo -iu acmesvc` tai `machinectl shell acmesvc@`)
- `PS>` = Windows-palvelimella PowerShell **järjestelmänvalvojana**

Keskuksen skriptit ovat polussa `/opt/acme/current/podman/scripts/` (lyhennetään `scripts/`).

---

## 1. Edellytykset

| Asia | Vaatimus | Tarkistus |
|---|---|---|
| Käyttöjärjestelmä | Windows Server 2016, 2019 tai 2022 | `winver` |
| Server 2016 | PFX-salaus vaatii keskuksessa `PFX_COMPAT=legacy` (koskee kaikkia PFX:iä) | ks. kohta 2 |
| .NET Framework | 4.7.2 tai uudempi (Release ≥ 461808) | `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' Release` |
| IIS | Web-Server + hallintatyökalut (WebAdministration) | `Get-Service W3SVC; Get-Module -ListAvailable WebAdministration` |
| PowerShell | Windows PowerShell 5.1 (sisältyy) | `$PSVersionTable.PSVersion` |
| Koodinallekirjoitus | `Install-Cert.ps1` ajetaan `-ExecutionPolicy AllSigned` -tilassa: allekirjoita skriptit organisaation koodinallekirjoitusvarmenteella ja luota julkaisijaan (`TrustedPublisher`) | `Get-AuthenticodeSignature .\Install-Cert.ps1` |
| Palomuuri | palvelin → Vault **TCP 8200** (keskuksen sisä-IP). Keskuksen firewalld sallii 8200 vain palvelinverkoista (`install-host.sh --server-cidrs`) | `Test-NetConnection vault.asiakas.fi -Port 8200` |
| Sulkulista | Ilmarako: oletus `RevocationMode=NoCheck` (ks. 9). Jos DVV:n CRL jaetaan Vaultin kautta: `Offline`. Online-tarkistus vaatisi yhteyden DVV:n CRL/OCSP-osoitteisiin (TCP 80), jota ilmaraossa ei ole. | `cert-install.json` |
| DNS | Vaultin nimi (esim. `vault.asiakas.fi`) ratkeaa keskuksen sisä-IP:hen | `Resolve-DnsName vault.asiakas.fi` |
| Aika | sisäinen NTP, poikkeama Vaultiin ≤ 60 s (esitarkistus mittaa Vaultin `Date`-otsakkeesta) | `w32tm /query /status` |
| IP-osoite | palvelimen IP on kiinteä: Vault sitoo tunnisteen IP:hen (`/32`). NAT palvelimen ja keskuksen välillä rikkoo sidonnan. | |

**Tarvittavat tiedostot** (julkaisupaketista, tarkista `SHA256SUMS`):

| Tiedosto | Lähde |
|---|---|
| `Install-WindowsAgent.ps1`, `Install-Cert.ps1`, `Setup-VaultAgent.ps1`, `Remove-WindowsAgent.ps1` | `release/<versio>/windows/` (allekirjoita) |
| `vault.exe` + SHA256 | `release/<versio>/bin/vault.exe`, summa `SHA256SUMS`:ssa ja `release/DEPENDENCIES.md`:ssä |
| `ca.pem` | keskuksen Vaultin TLS-CA: `/etc/acme-podman/tls/ca.pem` (ei salainen) |
| `dvv-ca.pem` | DVV:n juuri-CA virallisesta lähteestä; tarkista sormenjälki DVV:n julkaisemaa vasten |

Kopioi tiedostot palvelimelle esim. hakemistoon `C:\Install\acme\` (tai sisäiselle jaolle).
**Mitään ei ladata internetistä.**

## 2. Ennen liittämistä (keskuksessa)

1. Lisää varmenne `/etc/acme-podman/certs.conf`:iin (root): `nimi  domain[,domain...]`, esim.
   `intranet  intranet.asiakas.fi`. Nimi on myös Vault-polku `secret/certs/<nimi>`.
2. Jos ympäristössä on Windows Server 2016 -palvelimia: aseta `/etc/acme-podman/.env`:iin
   `PFX_COMPAT=legacy` (3DES/SHA1-PFX; 2019+ avaa myös tämän).
3. Tilaa varmenne heti:
   ```
   keskus$ systemctl --user start acme-renew.service
   keskus$ journalctl --user -t acme-renew -t acme-deploy -n 20
   ```
   Onnistuessa lokissa on `acme-deploy: Vaultiin päivitetty: intranet (...)`.
4. Tarkista, että varmenne on Vaultissa:
   ```
   keskus$ scripts/healthcheck.sh        # "varmenne intranet voimassa NN pv"
   ```

## 3. Liittäminen vaihe vaiheelta (yksi palvelin)

### 3.1 Onboarding keskuksessa (ylläpitäjä)

```
keskus$ scripts/onboard-server.sh add web01 10.1.2.31 intranet
Vault-käyttäjätunnus: etunimi.sukunimi
Salasana:
TOTP-koodi:
palvelin:           web01
role_id:            0b4e2b8e-...
wrapped secret_id:  hvs.CAES...   (voimassa 15m, kertakäyttöinen)
```

Tämä luo policyn `cert-web01` (luku vain annettuihin varmenteisiin) ja AppRole-roolin, jonka
tunnisteet toimivat vain osoitteesta `10.1.2.31/32`. secret_id on voimassa 90 pv (ks. 6.2).

### 3.2 Wrapping tokenin toimitus

- Kääre on **kertakäyttöinen ja vanhenee 15 minuutissa**. Se ei ole itse secret_id, vaan
  "kirjekuori", jonka vain ensimmäinen avaaja voi avata.
- Toimita kääre suoraan asentajalle turvallista kanavaa pitkin (esim. luettuna puhelimessa tai
  hallintayhteyden leikepöydän kautta). Älä lähetä sähköpostilla tai chatissa, jonne se jää.
- Jos 15 minuuttia ehtii kulua: `keskus$ scripts/onboard-server.sh wrap web01` (uusi kääre).

### 3.3 Asennus palvelimella

```powershell
PS> cd C:\Install\acme
PS> .\Install-WindowsAgent.ps1 -VaultAddress https://vault.asiakas.fi:8200 `
      -RoleId 0b4e2b8e-... `
      -Certificates @{ intranet = @('intranet.asiakas.fi:443') } `
      -CaPath .\ca.pem -DvvCaPath .\dvv-ca.pem `
      -VaultExeSource .\vault.exe -VaultExeSha256 <SHA256SUMS:sta> `
      -WrappingToken (Read-Host -AsSecureString 'Wrapping token')
```

Kokeile ensin `-WhatIf`:llä (näyttää muutokset tekemättä niitä). Skripti:

1. tekee **esitarkistukset ennen mitään muutoksia** ja tulostaa taulukon (Tarkistus, Ok, Tulos,
   Korjaus). Jos jokin epäonnistuu, mitään ei muuteta ja korjausohje näytetään;
2. asentaa `vault.exe`:n (`C:\Program Files\Vault`) SHA256-tarkistettuna;
3. kirjoittaa `agent.hcl`:n ja `cert-install.json`:n (`C:\ProgramData\vault-agent`);
4. luo puuttuvat IIS HTTPS -sidokset (SNI) sivustoon `Default Web Site` (`-IisSite` muuttaa);
5. ajaa `Setup-VaultAgent.ps1`:n (palvelu, ACL:t, tehtävä `Cert-Install`);
6. purkaa kääreen paikallisesti ja kirjoittaa secret_id:n tiedostoon, jonka ACL on vain SYSTEM,
   Administrators ja `NT SERVICE\vault-agent`;
7. käynnistää agentin ja odottaa (oletus 600 s), että `Install-Cert.ps1` on asentanut jokaisen
   varmenteen ja sidonut sen;
8. todentaa TLS-yhteydellä (SNI), että IIS tarjoilee juuri tätä varmennetta, ja tulostaa
   thumbprintin ja voimassaolon.

Valinnat: `-RevocationMode NoCheck|Offline|Online`, `-CrlStalePolicy Warn|Fail`, `-MinValidDays 7`,
`-TimeoutSeconds`, `-SkipVerify` (ei odotusta), `-Verbose`.

**Uudelleenajo on turvallinen:** se päivittää konfiguraation eikä luo duplikaatteja. Ilman
`-WrappingToken`ia nykyinen secret_id säilyy (esim. varmenteen lisäys palvelimelle).

## 4. Massaliittäminen

### 4.1 Parametritiedostot CSV:stä (keskuksessa)

`palvelimet.csv` (`palvelin;ip;varmenne=host:port|host:port[;varmenne=...]`):
```
# palvelin;ip;varmenteet
web01;10.1.2.31;intranet=intranet.asiakas.fi:443
web02;10.1.2.32;intranet=intranet.asiakas.fi:443;api=api.asiakas.fi:443|api2.asiakas.fi:443
```
```
keskus$ scripts/onboard-server.sh csv palvelimet.csv --out /tmp/params \
          --vault-exe-sha256 <SHA256> --revocation-mode NoCheck
```
Tuloksena `/tmp/params/<palvelin>.json` jokaiselle (role_id, Vault-osoite, varmenteet, polut).
**Tiedostoissa ei ole salaisuuksia.** Kääreet luodaan vasta asennushetkellä, koska ne vanhenevat
15 minuutissa.

### 4.2 Ansible (WinRM)

Ylläpitäjä kirjautuu kerran ja tallentaa tunnin voimassa olevan tokenin automaatiota varten:
```
keskus$ scripts/onboard-server.sh login ~/admin.token     # userpass + TOTP, tiedosto 0600
```

`liita-windows.yml` (inventory: ryhmä `windows_iis`, `ansible_connection: winrm`, keskus = `keskus`):
```yaml
- name: Liitä Windows-palvelimet DVV-varmennejakeluun
  hosts: windows_iis
  serial: 5                       # kääreet luodaan juuri ennen käyttöä
  vars:
    src: /srv/release/current     # julkaisupaketti ohjauskoneella
    params_dir: /tmp/params
  tasks:
    - name: Kopioi skriptit ja tiedostot
      ansible.windows.win_copy:
        src: "{{ item }}"
        dest: C:\Install\acme\
      loop:
        - "{{ src }}/windows/"
        - "{{ src }}/bin/vault.exe"
        - "{{ src }}/ca.pem"
        - "{{ src }}/dvv-ca.pem"
        - "{{ params_dir }}/{{ inventory_hostname_short }}.json"

    - name: Luo kääre keskuksessa
      ansible.builtin.command:
        cmd: /opt/acme/current/podman/scripts/onboard-server.sh wrap {{ inventory_hostname_short }}
      environment:
        VAULT_ADMIN_TOKEN_FILE: /var/lib/acmesvc/admin.token
      delegate_to: keskus
      become: true
      become_user: acmesvc
      register: wrap
      no_log: true

    - name: Asenna agentti
      ansible.windows.win_powershell:
        script: |
          param([string]$Token, [string]$Json)
          $t = ConvertTo-SecureString $Token -AsPlainText -Force
          & C:\Install\acme\Install-WindowsAgent.ps1 -ParameterFile $Json -WrappingToken $t
        parameters:
          Token: "{{ wrap.stdout | regex_search('hvs\\.[A-Za-z0-9_-]+') }}"
          Json: "C:\\Install\\acme\\{{ inventory_hostname_short }}.json"
      no_log: true
```
Poista token heti ajon jälkeen: `keskus$ shred -u ~/admin.token`. `no_log: true` estää kääreen
päätymisen Ansiblen lokeihin. Kääre on kertakäyttöinen, joten vuotanutta kääre-tekstiä ei voi
käyttää enää onnistuneen asennuksen jälkeen.

**SCCM/Intune:** sama periaate: jaa tiedostot ja parametritiedosto paketissa, ja anna kääre
asennushetkellä (esim. ajonaikainen muuttuja). Kääreen 15 minuutin aikaraja on huomioitava.

## 5. Todentaminen

```powershell
PS> Get-Service vault-agent                                   # Running
PS> Get-ScheduledTask Cert-Install | Get-ScheduledTaskInfo    # LastTaskResult 0
PS> Get-EventLog Application -Source cert-install -Newest 10 | Format-List TimeGenerated,EntryType,Message
PS> netsh http show sslcert hostnameport=intranet.asiakas.fi:443
PS> Get-ChildItem Cert:\LocalMachine\My | ? Subject -like '*intranet*' | fl Subject,Thumbprint,NotAfter,Issuer
```
`cert-install`-tapahtumat: `Information` = asennettu (thumbprint, voimassaolo, sidokset),
`Warning` = sidos korjattu tai sulkutila tuntematon (Offline/Warn), `Error` = hylätty (syy viestissä;
vanha varmenne jää voimaan).

TLS-testi toiselta koneelta:
```
openssl s_client -connect intranet.asiakas.fi:443 -servername intranet.asiakas.fi </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate -fingerprint -sha1
```
Fingerprintin on vastattava `netsh`-tulosteen `Certificate Hash` -arvoa.

## 6. Normaali elinkaari

### 6.1 Uusinta

| Vaihe | Missä | Milloin |
|---|---|---|
| lego uusii, kun voimassaoloa on alle `RENEW_DAYS` (30 pv) | keskus, `acme-renew.timer` | 03:00 ja 15:00 (+ satunnainen viive ≤ 1 h) |
| uusi PFX + salasana Vaultiin | keskus, `lego-hook.sh` | heti uusinnan jälkeen |
| agentti kirjoittaa staging-tiedoston | palvelin, Vault Agent | ≤ 1 h (`static_secret_render_interval`) |
| tarkistus, tuonti, sidosten päivitys, vanhan poisto | palvelin, `Cert-Install` | ≤ 15 min |

Yhteensä uusi varmenne on käytössä noin 1,5 tunnin kuluessa uusinnasta. Mitään ei tarvitse tehdä käsin.

### 6.2 secret_id:n kierrätys (90 pv)

secret_id vanhenee 90 päivässä (`SECRET_ID_TTL`). Kierrätä esim. kahden kuukauden välein:

1. `keskus$ scripts/onboard-server.sh rotate web01` → uusi kääre (vanha secret_id toimii vielä).
2. `PS> .\Install-WindowsAgent.ps1 -ParameterFile .\web01.json -WrappingToken (Read-Host -AsSecureString)`
   (tai sama parametreilla). Skripti vaihtaa secret_id:n ja käynnistää agentin uudelleen.
3. Tarkista, että agentti kirjautuu: `Get-Service vault-agent` on Running, ja tunnin sisällä
   `cert-install`-lokissa ei ole virheitä (tai aja `Restart-Service vault-agent` ja katso
   staging-tiedoston aikaleima).
4. `keskus$ scripts/onboard-server.sh destroy-old web01` → vanhat secret_id:t hävitetään.

### 6.3 Vault Agentin päivitys

Uusi `vault.exe` tulee julkaisupaketissa (summa `SHA256SUMS`:ssa). Aja `Install-WindowsAgent.ps1`
uudella `-VaultExeSource`/`-VaultExeSha256`:lla ilman `-WrappingToken`ia: skripti pysäyttää
palvelun, vaihtaa tiedoston, tarkistaa summan ja käynnistää palvelun uudelleen.

### 6.4 Varmenteen lisäys tai poisto palvelimelta

Lisää varmenne keskuksessa (`onboard-server.sh add web01 10.1.2.31 intranet api` päivittää policyn),
ja aja `Install-WindowsAgent.ps1` uudella `-Certificates`-listalla ilman `-WrappingToken`ia.

## 7. Vianmääritys

| Oire | Todennäköinen syy | Korjaus |
|---|---|---|
| Esitarkistus "Vaultin tila: SINETÖITY"; agentin lokissa `Vault is sealed` (503) | Keskus käynnistyi uudelleen; Vault avataan aina käsin | Keskuksen ylläpito: `scripts/vault-unseal.sh` (kynnys 3/5 avainosaa) |
| Agentin lokissa `permission denied` / `source address unauthorized` kirjautumisessa | CIDR-sidonta ei täsmää: palvelimen IP vaihtunut, väärä IP onboardingissa tai NAT välissä | `onboard-server.sh remove web01` ja `add` oikealla IP:llä; ei NATia palvelin → keskus |
| Kääreen purku: "Kääre on jo käytetty tai vanhentunut" | Yli 15 min kulunut, tai joku muu on purkanut kääreen | Jos et itse käyttänyt: **mahdollinen vuoto**, ilmoita, aja `onboard-server.sh remove` + `add`. Muuten `onboard-server.sh wrap web01` |
| Esitarkistus "Vaultin TLS (ca.pem)" epäonnistuu | Väärä `ca.pem`, nimi ei ole Vaultin varmenteen SAN:ssa, tai yhteys menee välityspalvelimen kautta | Käytä keskuksen `/etc/acme-podman/tls/ca.pem`; käytä samaa nimeä kuin `VAULT_API_ADDR`; ei TLS-välityspalvelinta |
| Esitarkistus "Kellon poikkeama Vaultiin" > 60 s | Palvelimen tai keskuksen aika väärin | `w32tm /resync /force`; tarkista NTP-lähde (`w32tm /query /source`) ja keskuksen chrony |
| `cert-install` Error: "ketju ei päädy DVV:n juureen" | Väärä `dvv-ca.pem` (esim. testijuuri) tai keskus tilaa väärästä ACME-palvelusta | Vertaa `dvv-ca.pem`:n sormenjälkeä DVV:n julkaisemaan; tarkista keskuksen `LEGO_SERVER` |
| `cert-install` Error: `RevocationStatusUnknown` / `OfflineRevocation` | `RevocationMode=Online` tai `Offline` ilman tuoretta CRL:ää, eikä yhteyttä DVV:n CRL:ään | Ilmaraossa `-RevocationMode NoCheck` (tai `Offline` + `-CrlStalePolicy Warn`, kun CRL jaetaan) |
| `cert-install` Error: PFX:n avaus (`The specified network password is not correct`, `ASN1 bad tag`) | Server 2016 ei avaa AES-256-PFX:ää | Keskus: `PFX_COMPAT=legacy` .env:iin ja pakota uusinta (runbook) |
| `cert-install` Error: "sidoksen add/update epäonnistui" | IIS-sivustolla ei ole HTTPS-sidosta, portti varattu toiselle sovellukselle tai väärä appid | Aja `Install-WindowsAgent.ps1` uudelleen (luo sidoksen); `netsh http show sslcert` ristiriitojen varalta |
| Tehtävä `Cert-Install` ei aja: `LastTaskResult` 0x1, lokissa ei mitään | `Install-Cert.ps1` allekirjoittamaton tai muutettu (AllSigned) | Allekirjoita uudelleen; `Get-AuthenticodeSignature C:\ProgramData\vault-agent\Install-Cert.ps1` |
| Varmenne asentunut (`Information`-tapahtuma), mutta IIS tarjoilee vanhaa | IP-pohjainen sidos (`0.0.0.0:443` / `ipport=`) tai Centralized Certificate Store ohittaa; selain/kuormantasaaja välimuistissa | `netsh http show sslcert` → poista vanha `ipport`-sidos tai käytä SNI:tä; `Install-Cert` korjaa SNI-sidoksen seuraavalla ajolla ("sidos korjattu"); tarkista kuormantasaajan varmenne |
| Agentti ei käynnisty (`Get-Service vault-agent` Stopped) | `agent.hcl` virheellinen, `vault.exe` puuttuu tai ACL väärin | `& 'C:\Program Files\Vault\vault.exe' agent -config=C:\ProgramData\vault-agent\agent.hcl` ylläpitäjänä näyttää virheen; aja Install-WindowsAgent uudelleen |
| Kirjautuminen toimi, mutta 90 pv:n jälkeen `invalid secret id` | secret_id vanhentunut | Kierrätä (6.2) |
| Template-virhe `missing key` | Varmennetta ei ole Vaultissa (nimi väärin tai ei vielä tilattu) | Kohta 2; tarkista `certs.conf`:n nimi |

## 8. Palvelimen poisto jakelusta

```powershell
PS> .\Remove-WindowsAgent.ps1 -Server web01 -WhatIf     # näytä ensin
PS> .\Remove-WindowsAgent.ps1 -Server web01             # palvelu, tehtävä, tunnisteet, staging
```
Lisävalinnat: `-RemoveCertificates` (poistaa hallittujen varmenteiden http.sys-sidokset ja DVV:n
myöntämät varmenteet), `-RemoveFiles` (koko hakemisto ja vault.exe). Oletuksena varmenteet ja
IIS-sidokset jäävät, jotta palvelu ei katkea.

Viimeistele keskuksessa (skripti tulostaa komennon):
```
keskus$ scripts/onboard-server.sh remove web01
```
Tämä hävittää kaikki roolin secret_id:t ja poistaa roolin ja policyn `cert-web01`.

## 9. Tietoturvahuomiot

**Mitä palvelimella on levyllä**

| Tiedosto | Sisältö | Lukuoikeus |
|---|---|---|
| `C:\ProgramData\vault-agent\secret_id` | AppRole secret_id (90 pv, IP-sidottu) | SYSTEM, Administrators, `NT SERVICE\vault-agent` |
| `role_id` | roolin tunniste (ei yksinään riitä) | sama |
| `staging\<nimi>.pfx.txt` | PFX + sen satunnainen salasana (eli käytännössä yksityinen avain) | SYSTEM, Administrators, agentti (Modify) |
| Koneen varmennesäilö | asennettu varmenne, avain **ei-vietävänä** | SYSTEM, IIS |
| `agent.hcl`, `cert-install.json`, `ca.pem`, `dvv-ca.pem` | asetukset, ei salaisuuksia | SYSTEM, Administrators, agentti (luku) |

Vault-token on vain agentin muistissa (ei token-sinkkiä eikä listeneriä).

**Jos palvelin murretaan** (hyökkääjällä ylläpitäjä- tai SYSTEM-oikeus): hyökkääjä saa palvelimen
nykyisten varmenteiden yksityiset avaimet ja voi hakea Vaultista **vain tämän palvelimen policyn
varmenteet, vain tämän palvelimen IP-osoitteesta**, kunnes secret_id hävitetään. Toimi näin:

1. `keskus$ scripts/onboard-server.sh remove web01` (secret_id:t hävitetään heti; agentti ei enää
   saa uusia varmenteita).
2. Pyydä DVV:ltä palvelimen varmenteiden sulkeminen.
3. Pakota uusi varmenne keskuksessa (`docs/runbook.md`: pakotettu uusinta), jotta muut saman
   varmenteen palvelimet saavat uuden avaimen.
4. Asenna palvelin puhtaaksi ja liitä uudelleen (`add`).

**Suositukset**
- Käytä palvelinkohtaisia varmenteita aina kun mahdollista: jaettu varmenne (sama nimi monella
  palvelimella) tarkoittaa, että yhden palvelimen murto vaarantaa kaikkien avaimen.
- Ilman online-sulkutarkistusta (`NoCheck`) suljettu varmenne hyväksyttäisiin asennuksessa;
  korvaava kontrolli on, että vain keskus voi kirjoittaa Vaultiin (`acme-writer`) ja suljetun
  varmenteen tilalle jaetaan uusi pakotetulla uusinnalla.
- Koodinallekirjoitus (AllSigned) estää muutetun `Install-Cert.ps1`:n ajamisen SYSTEMinä.
- Kääreet toimitetaan aina erillään parametritiedostoista; parametritiedostoissa ei ole salaisuuksia.
