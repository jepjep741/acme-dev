# CLAUDE.md – DVV ACME -keskitetty varmennehallinta

## Mitä tämä projekti on
Keskuspalvelin tilaa ja uusii DVV:n palvelinvarmenteet **legolla** (HTTP-01, EAB) ja
tallentaa ne **Vaultiin**. ~100 Linux- ja Windows-palvelinta hakevat omat
varmenteensa **Vault Agentilla** (AppRole) staging-hakemistoon, ja erillinen
root/SYSTEM-osa asentaa ne vasta tarkistusten jälkeen. Palvelimet eivät tiedä ACME:sta mitään.
Arkkitehtuuri: README.md ja dvv-acme-arkkitehtuuri.excalidraw.

Keskus ajetaan **rootless Podmanilla** (`podman/`, RHEL 9, podman-compose) **ilmaraossa**: ainoa
ulkoinen yhteys on lego → DVV. Isäntäkoneversio `keskus/` on vain viite, sitä ei kehitetä.

## Hakemistot
- `podman/`  – compose (nginx, Vault, lego), lego-image, vault.hcl + policyt, systemd-yksiköt, `scripts/`
- `keskus/`  – isäntäkoneversio (viite, ei muuteta)
- `linux/`   – Vault Agent + systemd-kovennus, cert-install.path/.service, install-cert.sh
- `windows/` – Install-WindowsAgent.ps1, Remove-WindowsAgent.ps1, Install-Cert.ps1 (PFX), Setup-VaultAgent.ps1
- `docs/`    – asennus, Windows-liittäminen, runbook, verkko, päivitys ilmaraossa
- `tests/`   – bats (`tests/podman`), Pester (`tests/windows`), lint
- `release/` – DEPENDENCIES.md ja julkaisupaketit (build-release.sh)

## Turvallisuussäännöt (ÄLÄ riko näitä)
- Salaisuuksia (EAB KID/HMAC, Vault-tokenit, secret_id, PFX-salasanat, avainosat) EI koskaan
  komentoriville, lokeihin eikä stdoutiin. Välitä tiedostoina (0400/0600) tai ympäristömuuttujina.
- Keskuksessa salaisuudet ovat **vain podman secretejä** (`/run/secrets/`); ei compose-tiedostoissa,
  `.env`:ssä, kontin ympäristömuuttujissa (`podman inspect`) eikä `podman exec -e`:ssä.
  Vault-komennot ajetaan vault-kontissa ja token annetaan **stdinin ensimmäisenä rivinä**
  (`podman/scripts/lib.sh: vault_tok`). Arvot Vaultille `key=-` (stdin) tai JSON stdinistä.
- `podman run` -kontin stdout menee journaldiin: salaisuutta tulostavissa ajoissa `--log-driver none`.
- Vault Agent ajetaan vähäoikeuksisena (Linux `vault-agent`, Windows `NT SERVICE\vault-agent`).
  Vain asennusosa (install-cert.sh / Install-Cert.ps1) ajetaan root/SYSTEMinä.
- Asennusosan tarkistuksia (avain vastaa, ketju DVV:n juureen, voimassaolo, ei vanhempi)
  ei saa poistaa eikä ohittaa.
- secret_id toimitetaan response-wrapattuna ja puretaan vasta kohdepalvelimella. AppRole sidotaan
  palvelimen IP:hen (/32). Siksi Vault on isännän verkossa (rootlessport hävittäisi lähde-IP:n).
- Binäärit (lego, vault) ladataan vain virallisista lähteistä ja SHA256-tarkistetaan; imaget
  kiinnitetään digestillä; tuotannossa ei vedetä mitään verkosta (`pull_policy: never`).
- Windowsilla yksityinen avain tuodaan ei-vietävänä.
- Root-token mitätöidään alustuksen jälkeen; ylläpitäjät kirjautuvat userpass + TOTP.

## Koodikäytännöt
- Bash: `set -euo pipefail` (paitsi tarkoitukselliset poikkeukset kommentoituna), shellcheck-puhdas,
  funktiot, `--dry-run` ja `--help` asennusskripteissä. `vault status` palauttaa 2 sinetöitynä:
  käytä `lib.sh: vault_status_json`, älä paljasta paluukoodia pipefail-putkessa.
- Funktiot, jotka palauttavat arvon `printf -v`:llä, nimeävät paikalliset muuttujat yksilöllisesti
  (bashin dynaaminen näkyvyys).
- PowerShell: yhteensopiva **Windows PowerShell 5.1** kanssa, PSScriptAnalyzer-puhdas (PS 5.1
  -profiilit), `-WhatIf`-tuki, tiedostot **UTF-8 BOM:lla** (PS 5.1 lukee BOM:ittoman ANSI:na),
  pääkulku vain `if ($MyInvocation.InvocationName -ne '.')` -ehdolla (Pester dot-sourcettaa).
- Compose: `mode` merkkijonona (`"0400"`); podman-compose 1.5 (EPEL 9) on mitta, ei docker-compose.
- Skriptien on oltava **idempotentteja**: uudelleenajo ei riko mitään eikä monista asetuksia.
- Lokiviestit suomeksi; virheissä kerro mitä tehdä seuraavaksi.
- Esimerkkiarvot (vault.asiakas.fi, intranet, asiakas.fi) tulevat parametreista/konfiguraatiosta, eivät kovakoodattuina.

## Testaus
- `tests/lint.sh` – shellcheck, hadolint, yamllint, podman-compose config (konteista)
- `tests/run-bats.sh` – `tests/podman/e2e.bats` (Pebble + Vault + lego + Linux-asiakas + Vault Agent,
  eristys, salaisuusvuodot, unseal, varmuuskopio ja palautus, onboarding) ja `host.bats`
  (install-host.sh ja nftables RHEL 9 -yhteensopivassa kontissa).
  Käytä EPEL 9:n podman-compose 1.5.0:aa: `PODMAN_COMPOSE=<venv>/bin/podman-compose`.
- `tests/windows/run.sh` – PSScriptAnalyzer ja Pester (pwsh-kontissa, Windows-komennot mockattu)
- Oikeaa DVV:tä ei käytetä testeissä: Pebble (EAB pakollinen) ja testi-CA:t.
- Batsissa taustalle jäävät prosessit (`compose up -d`, `run -d`) tarvitsevat `3>&-`.
- Ei saa siirtyä seuraavaan vaiheeseen, jos testit tai lintterit eivät mene läpi (tarkista
  paluukoodi, älä peitä sitä putkella).
