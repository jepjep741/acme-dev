# Muutosloki

## 1.0.0 (luonnos)
Ensimmäinen konttiversio (rootless Podman) ilmarakoon.

- Keskus: nginx (internal-verkko), Vault 2.1.1 (raft, TLS, isännän verkko vain sisä-IP:ssä),
  lego 5.5.2 ajastettuna kertakonttina; salaisuudet podman secreteinä.
- Vaultin alustus (5/3, PGP valinnainen), ylläpitäjät userpass + TOTP, root-token mitätöidään.
- Varmuuskopio (raft-snapshot, GPG-salattu lego-data) ja testattu palautus.
- Egress-rajaus nftablesilla (vain DVV + DNS) ja `egress-check.sh`.
- Windows: `Install-WindowsAgent.ps1` (esitarkistukset, kääreen purku, IIS-sidokset, todennus),
  `Remove-WindowsAgent.ps1`; `Install-Cert.ps1`: RevocationMode-asetus, sidosten korjaus, BOM.
- Julkaisupaketti: OCI-arkistot digestit säilyttäen, SBOM ja haavoittuvuusraportit, GPG-allekirjoitus.
- Muutokset isäntäkoneversioon verrattuna: lego v5 (tilin siirto v4:stä ei mahdollinen),
  haastetiedostojen umask korjattu.
