# Julkaisupaketti ja päivitys ilmaraossa

Ilmaraon puolella mitään ei haeta verkosta. Kaikki imaget ja binäärit tulevat allekirjoitetussa
julkaisupaketissa, ja sen allekirjoitus ja tarkistussummat todennetaan **ennen** kuin mitään ladataan.

## 1. Rakennus (ilmaraon ulkopuolella)

Rakennusympäristö: Linux, podman, gpg, verkkoyhteys rekistereihin, GitHubiin ja releases.hashicorp.comiin.
```
podman/scripts/build-release.sh --version 1.0.0 --gpg-key <julkaisuavaimen sormenjälki>
```
Skripti:
1. rakentaa lego-imagen (`versions.env`: lego ja vault CLI SHA256-tarkistettuina);
2. kopioi nginx- ja Vault-imaget rekisteristä **digestit säilyttäen** (`skopeo --preserve-digests`)
   ja vie lego-imagen OCI-arkistoksi (toistettava digest). Digestit ovat `IMAGES.txt`:ssä;
3. hakee `vault.exe`:n ja tarkistaa HashiCorpin GPG-allekirjoituksen (sormenjälki `versions.env`);
4. kopioi `podman/`, `windows/`, `linux/` ja `docs/` ilman kehitys- ja testitiedostoja (Pebble,
   `compose.dev.yaml`, `tests/` eivät kuulu pakettiin);
5. tuottaa SBOMin (syft, SPDX) ja haavoittuvuusraportin (trivy) jokaisesta imagesta
   (`sbom/`, `scan/`, yhteenveto `scan/SUMMARY.txt`);
6. laskee `SHA256SUMS`:n kaikista tiedostoista ja allekirjoittaa sen (`SHA256SUMS.asc`).

Tulos: `release/<versio>/` ja siirtoa varten `release/acme-release-<versio>.tar`.
**Arvioi `scan/SUMMARY.txt` ennen siirtoa.** Kriittiset haavoittuvuudet korjataan päivittämällä
pohjaimage tai versio ja rakentamalla uudelleen.

**Allekirjoitusavain:** julkaisuavaimen julkinen osa (`release-signing-key-<versio>.asc`) on
luottamusankkuri. Se toimitetaan ilmarakoon **kerran ja eri kanavaa pitkin** kuin paketit, ja sen
sormenjälki tarkistetaan puhelimitse tai paperilla. Paketin mukana tuleva avain ei ole luotettava.
Avain säilytetään keskuksessa esim. `/etc/acme-podman/release-signing-key.asc` (root, 0644).

## 2. Siirto
Siirrä `acme-release-<versio>.tar` organisaation siirtomenettelyllä (tarkastettu media tai
siirtopalvelu). Ilmoita tarin SHA256 erikseen vastaanottajalle (`sha256sum acme-release-<versio>.tar`).

## 3. Tuonti (ilmarako, root)
```
root# sha256sum acme-release-1.0.0.tar          # vertaa erikseen ilmoitettuun
root# tar -xf acme-release-1.0.0.tar -C /var/tmp
root# /var/tmp/1.0.0/podman/scripts/import-release.sh /var/tmp/1.0.0 \
        --pubkey /etc/acme-podman/release-signing-key.asc --verify-only
root# /var/tmp/1.0.0/podman/scripts/import-release.sh /var/tmp/1.0.0 \
        --pubkey /etc/acme-podman/release-signing-key.asc            # [--activate]
```
`import-release.sh`:
1. tarkistaa allekirjoituksen (`gpgv`) annettua avainta vasten;
2. tarkistaa kaikki summat (`sha256sum --strict`) ja että paketissa ei ole listaamattomia tiedostoja;
3. kopioi paketin `/opt/acme/releases/<versio>`:iin (root, vain luku) ja palauttaa SELinux-kontekstit;
4. lataa imaget palvelukäyttäjälle (`podman load`) ja tarkistaa, että ne löytyvät **kiinnitetyillä
   digesteillä** (`IMAGES.txt`);
5. asettaa `/opt/acme/current`-linkin vain ensiasennuksessa tai `--activate`-valinnalla;
6. tulostaa julkaisun image-viitteet. `.env`:iä ei muuteta automaattisesti.

Mikä tahansa poikkeama keskeyttää tuonnin ennen kuin mitään ladataan tai kopioidaan.

## 4. Päivitysmenettely

Uusi julkaisu tuodaan **rinnalle**; vanha jää paikalleen palautusta varten.

| # | Vaihe | Komennot |
|---|---|---|
| 1 | Tila ja varmuuskopio ennen muutoksia | `acmesvc$ scripts/healthcheck.sh; scripts/smoke-test.sh; scripts/backup.sh` |
| 2 | Tuonti (ei aktivoi) | `root# import-release.sh <paketti> --pubkey ...` |
| 3 | Muutokset luettavaksi | `/opt/acme/releases/<uusi>/CHANGELOG.md` ja `diff -r` vanhaan `podman/`-hakemistoon |
| 4 | Aktivointi (skriptit, compose, systemd) | `root# import-release.sh <paketti> --pubkey ... --activate; install-host.sh install ...` (päivittää yksiköt) |
| 5 | nginx | `.env`: `NGINX_IMAGE=<uusi>` → `acmesvc$ scripts/acme-compose.sh up -d nginx` → `smoke-test.sh` |
| 6 | lego | `.env`: `LEGO_IMAGE=<uusi>` → `acme-compose.sh --profile jobs run --rm -T lego --dry-run` → `systemctl --user start acme-renew.service` → lokit |
| 7 | **Vault viimeisenä, hallitusti** | ilmoita avainosien haltijoille; `backup.sh`; `.env`: `VAULT_IMAGE=<uusi>` → `acme-compose.sh up -d vault` → `vault-unseal.sh` → `healthcheck.sh` → `smoke-test.sh` → testaa yhden agentin haku |
| 8 | Lopuksi | `egress-check.sh`, `backup.sh`; säilytä edellinen julkaisu vähintään seuraavaan päivitykseen |

Windows-palvelimille päivitetyt skriptit ja `vault.exe` jaetaan `windows-liittaminen.md`:n kohdan 6.3
mukaan (`Install-WindowsAgent.ps1` ilman kääreettä).

## 5. Palautus edelliseen julkaisuun

1. `root# ln -sfn /opt/acme/releases/<edellinen> /opt/acme/current` (tai `import-release.sh <edellinen> --activate`)
2. Palauta edelliset image-viitteet `.env`:iin (ne ovat `/opt/acme/releases/<edellinen>/IMAGES.txt`:ssä;
   imaget ovat yhä palvelukäyttäjän tallennuksessa) ja `acme-compose.sh up -d <palvelu>`.
3. Vault: jos vanha versio ei käynnisty uuden version kirjoittamalla datalla, palauta päivitystä
   edeltänyt snapshot: `restore.sh vault <kopio>` (vaatii ylläpitäjän) ja `vault-unseal.sh`.
4. `smoke-test.sh`, `healthcheck.sh`.

Vanhojen imagejen siivous vasta, kun uusi julkaisu on todettu toimivaksi:
`acmesvc$ podman image prune` (poistaa vain käyttämättömät).

## 6. Sisäinen konttirekisteri (vaihtoehto)

Oletus on OCI-arkistot ja `podman load`, koska sisäistä rekisteriä ei ole vahvistettu. Jos
rekisteri otetaan käyttöön:
- vie arkistot rekisteriin digestit säilyttäen:
  `skopeo copy --preserve-digests oci-archive:images/nginx.oci.tar docker://rekisteri.sisainen/acme/nginx-unprivileged:<versio>`;
- muuta `.env`:n viitteet muotoon `rekisteri.sisainen/acme/...@sha256:<sama digest>`;
- vaadi allekirjoitus `/etc/containers/policy.json`:ssa näille poluille (esim. sigstore/cosign-
  tai GPG-allekirjoitus, `"type": "signedBy"` / `"sigstoreSigned"`) ja salli muut vain
  `"reject"`-oletuksella. Tämä on toteutettava ja testattava asiakkaan rekisterin kanssa.
- `pull_policy: never` säilyy: image haetaan rekisteristä erillisellä, valvotulla komennolla
  (`podman pull ...@sha256:`) eikä compose koskaan hae itse.

## 7. Savutesti ja diagnostiikka
- `scripts/smoke-test.sh` toimii täysin offline: kontit, Vault avattu, haastepolku nginxissä,
  viimeisin onnistunut uusinta, varmenteiden `not_after` Vaultissa (ilman pääsyä avaimiin).
- `scripts/collect-diagnostics.sh` kerää lokit ja tilan arkistoon **ilman salaisuuksia**: tunnetut
  muodot poistetaan ja jokaisen podman secretin todellista arvoa etsitään arkistosta; jos sellainen
  löytyy, arkistoa ei luoda. Tarkista arkisto (`tar -tzvf`) ennen vientiä ilmaraosta.
