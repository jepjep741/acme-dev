# CLAUDE.md – DVV ACME -keskitetty varmennehallinta

## Mitä tämä projekti on
Keskuspalvelin tilaa ja uusii DVV:n palvelinvarmenteet **legolla** (HTTP-01, EAB) ja
tallentaa ne **Vaultiin/OpenBaoon**. ~100 Linux- ja Windows-palvelinta hakevat omat
varmenteensa **Vault Agentilla** (AppRole) staging-hakemistoon, ja erillinen
root/SYSTEM-osa asentaa ne vasta tarkistusten jälkeen. Palvelimet eivät tiedä ACME:sta mitään.
Arkkitehtuuri: README.md ja dvv-acme-arkkitehtuuri.excalidraw.

## Hakemistot
- `keskus/`  – lego, lego-hook, systemd-timer, nginx (:80 acme-challenge), Vault-policyt, onboarding
- `linux/`   – Vault Agent + systemd-kovennus, cert-install.path/.service, install-cert.sh
- `windows/` – Vault Agent -palvelu, Install-Cert.ps1 (PFX), Setup-VaultAgent.ps1
- `install/` – asennusskriptit (rakennetaan)
- `tests/`   – bats (bash) ja Pester (PowerShell) -testit

## Turvallisuussäännöt (ÄLÄ riko näitä)
- Salaisuuksia (EAB KID/HMAC, Vault-tokenit, secret_id, PFX-salasanat) EI koskaan
  komentoriville, lokeihin eikä stdoutiin. Välitä tiedostoina (0400/0600) tai ympäristömuuttujina.
- Vault Agent ajetaan vähäoikeuksisena (Linux `vault-agent`, Windows `NT SERVICE\vault-agent`).
  Vain asennusosa (install-cert.sh / Install-Cert.ps1) ajetaan root/SYSTEMinä.
- Asennusosan tarkistuksia (avain vastaa, ketju DVV:n juureen, voimassaolo, ei vanhempi)
  ei saa poistaa eikä ohittaa.
- secret_id toimitetaan response-wrapattuna ja puretaan vasta kohdepalvelimella.
- Binäärit (lego, vault) ladataan vain virallisista lähteistä ja SHA256-tarkistetaan.
- Windowsilla yksityinen avain tuodaan ei-vietävänä.

## Koodikäytännöt
- Bash: `set -euo pipefail`, shellcheck-puhdas, funktiot, `--dry-run` ja `--help` kaikissa asennusskripteissä.
- PowerShell: yhteensopiva **Windows PowerShell 5.1** kanssa, PSScriptAnalyzer-puhdas, `-WhatIf`-tuki.
- Skriptien on oltava **idempotentteja**: uudelleenajo ei riko mitään eikä monista asetuksia.
- Lokiviestit suomeksi; virheissä kerro mitä tehdä seuraavaksi.
- Esimerkkiarvot (vault.asiakas.fi, intranet, asiakas.fi) tulevat parametreista/konfiguraatiosta, eivät kovakoodattuina.

## Testaus
- `shellcheck install/*.sh keskus/*.sh linux/*.sh`
- `bats tests/`
- `pwsh -c "Invoke-ScriptAnalyzer -Path windows,install -Recurse"` ja `Invoke-Pester tests/`
- Oikeaa DVV:tä ei käytetä testeissä: käytä itse allekirjoitettua test-CA:ta ja
  Vaultin dev-tilaa (`vault server -dev`) tai stub-komentoja.
