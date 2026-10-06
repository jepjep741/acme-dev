# Ulkoiset riippuvuudet

Kaikki versiot ja tarkistussummat ovat koneluettavina tiedostossa `podman/versions.env` ja
`podman/.env.example`. Tämä taulukko on niiden ihmisluettava kuvaus. Päivitys: muuta
`versions.env`/`.env.example`, aja testit (`tests/lint.sh`, `tests/run-bats.sh`, `tests/windows/run.sh`)
ja rakenna julkaisu (`podman/scripts/build-release.sh`).

**Luottamusmalli:** imaget kiinnitetään digestillä (`@sha256:`), binäärit SHA256-summalla.
Lähdekohtainen todennus mainitaan sarakkeessa "Tarkistus".

## Julkaisupakettiin (ilmarako)

| Komponentti | Versio | Lähde | Kiinnitys | Tarkistus |
|---|---|---|---|---|
| nginx-unprivileged (image) | 1.30.5, stable-alpine-slim | docker.io/nginxinc/nginx-unprivileged | `sha256:bfcf1250dae73fb5dafe18b9fa64d033441510c5a2fc7a11cf8003087890301b` (linux/amd64-manifesti) | digest; skopeo `--preserve-digests` |
| HashiCorp Vault (image) | 2.1.1 | docker.io/hashicorp/vault | `sha256:8af37ae9d45e4a0fac48ab700e0d99efc4c2d6cd84354a869f2147f1d3abab46` | digest |
| acme-lego (oma image) | 5.5.2-1 | `podman/images/lego/Containerfile` | digest julkaisun `IMAGES.txt`:ssä (toistettava) | rakennetaan julkaisussa |
| ↳ UBI 9 minimal (pohja) | 9.8 | registry.access.redhat.com/ubi9/ubi-minimal | `sha256:eba570d04193d1523a8576b1c0ff00e681c9edb1a41d4742559b6e3ff457601e` | digest; paketit Red Hatin allekirjoittamista UBI-varastoista (microdnf) |
| ↳ lego | 5.5.2 linux/amd64 | github.com/go-acme/lego/releases | SHA256 `2a35505089e7772c92e1e9ac144df91151ef2eca8568630db0ff91fca06d9bef` | projektin `lego_5.5.2_checksums.txt` |
| ↳ vault CLI | 2.1.1 linux/amd64 | releases.hashicorp.com | SHA256 `8aa90f9cea46f541fc7baa3d0ec692fc06afde9a248cc1f2dcac46a567c6f56b` | HashiCorpin GPG-allekirjoitettu SHA256SUMS (avain `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`) |
| vault.exe (Windows-agentti) | 2.1.1 windows/amd64 | releases.hashicorp.com | SHA256 (zip) `e07a39059d7c7380d6dc776fb5bee2183cbc3344cf9387d4cf11309b83c0dce3` | HashiCorpin GPG-allekirjoitus; `bin/vault.exe`:n summa paketin SHA256SUMS:ssa |

## Keskuspalvelimen käyttöjärjestelmäpaketit (RHEL 9)

| Paketti | Testattu versio | Lähde |
|---|---|---|
| podman | 5.8.2 (RHEL 9.8 AppStream) | asiakkaan RHEL-varasto |
| podman-compose | 1.5.0 (EPEL 9) | asiakkaan EPEL-peili (vahvistettu saatavilla). Ei sisälly pakettiin. |
| nftables, firewalld, openssl, policycoreutils-python-utils, gnupg2 (gpgv), python3 | RHEL 9.8 | RHEL-varasto |

Jos EPEL ei olisi saatavilla: lisää `podman-compose`-RPM ja riippuvuudet (`python3-pyyaml`,
`python3-dotenv`) julkaisun `bin/rpm/`-hakemistoon (`dnf download --resolve`) ja asenna
`install-host.sh --skip-packages` -tilassa käsin.

## Palvelimet

| Komponentti | Vaatimus |
|---|---|
| Windows Server | 2016 (PFX legacy), 2019, 2022; Windows PowerShell 5.1; .NET Framework ≥ 4.7.2; IIS |
| Linux | `linux/`: Vault Agent (vault-binääri jaellaan asiakkaan tavalla), openssl, systemd |

## Vain rakennus- ja testiympäristö (EI julkaisupakettiin)

| Työkalu | Versio | Kiinnitys |
|---|---|---|
| Pebble / pebble-challtestsrv | 2.10.1 | `PEBBLE_IMAGE`, `CHALLTESTSRV_IMAGE` (versions.env) |
| bats-core | 1.13.0 | GitHub-arkiston SHA256 `a85e12b8...` (TOFU: projekti ei julkaise summia arkistoille) |
| shellcheck / hadolint / yamllint | 0.11.0 / 2.14.0 / latest@digest | versions.env |
| pwsh + Pester + PSScriptAnalyzer | 7.4 LTS / 5.7.1 / 1.25.0 | `tests/windows/Containerfile` (PSGallery) |
| Rocky Linux 9 (testi-isäntä) | 9.8 | `tests/podman/rhel-host/Containerfile` digest |
| skopeo / syft / trivy | 1.22.3 / 1.54.0 / 0.75.0 | versions.env (`SKOPEO_IMAGE`, `SYFT_IMAGE`, `TRIVY_IMAGE`) |
| podman-compose (testit) | 1.5.0 (pip, sama kuin EPEL 9) | `PODMAN_COMPOSE`-ympäristömuuttuja |

SBOMit (`sbom/*.spdx.json`) ja haavoittuvuusraportit (`scan/*.trivy.json`, `scan/SUMMARY.txt`)
tuotetaan jokaisesta imagesta julkaisun rakennuksessa ja ne sisältyvät pakettiin.
