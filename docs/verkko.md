# Verkkoyhteydet (ilmarako)

Kohdeympäristössä keskuspalvelimella on **vain** yhteys DVV:hen. Palvelimilla ja Vaultilla ei ole
yhteyttä ulos. Tässä on tarkka lista sallituista yhteyksistä. Muu liikenne on estetty, ja
`scripts/egress-check.sh` todentaa rajauksen.

## Sallitut yhteydet tuotannossa

| # | Lähde | Kohde | Portti | Huom. |
|---|---|---|---|---|
| 1 | lego-kontti (palvelukäyttäjä `acmesvc`, isännän verkko) | DVV ACME | TCP 443 | ainoa ulospäin; suora tai allowlist-välityspalvelin (`HTTPS_PROXY` vain lego-kontille) |
| 2 | lego-kontti | DVV:n CRL/OCSP | TCP 80 | vain jos CRL-jakelu otetaan käyttöön (oletus: ei) |
| 3 | DVV:n validaattorit | palomuuri → DNAT → keskus `:8080` | TCP 80 → 8080 | HTTP-01. Rajaa validaattoreiden osoitteisiin perimetrissä, jos DVV ne julkaisee. nginx ei näe asiakkaan IP:tä (rootless-portinohjaus), joten rajaus on tehtävä palomuurissa |
| 4 | Windows/Linux-palvelimet | keskus `VAULT_BIND_IP:8200` | TCP 8200 | sisäverkko; firewalld sallii vain `--server-cidrs` |
| 5 | keskus | sisäinen DNS | UDP/TCP 53 | palvelukäyttäjälle sallitaan vain `--dns`-palvelimet |
| 6 | keskus | sisäinen NTP | UDP 123 | chronyd (järjestelmä, ei palvelukäyttäjä) |
| 7 | ylläpitäjä | keskus | TCP 22 | hallinta |

Kaikki muu ulosmenevä liikenne palvelukäyttäjältä (myös imagerekisterit ja yleinen internet) hylätään.

## Toteutus keskuksessa

**Kaksi kerrosta:**
1. **Konttiverkko:** nginx on `internal`-verkossa `edge` (ei oletusreittiä, ei pääsyä isäntään eikä Vaultiin).
2. **Isäntä (nftables):** rootless-tilassa kaikkien konttien ulosmenevä liikenne lähtee
   palvelukäyttäjän prosesseista (pasta, kontit isännän verkossa). Taulu `inet acme_egress` rajaa
   paketit, joiden `meta skuid` on `acmesvc`: sallitaan loopback, vastaukset, `--dns`-palvelimet ja
   `--egress-allow`-kohteet; muu hylätään (`reject`) ja kirjataan (`acme-egress-drop:`, enintään 6/min).
   Muut käyttäjät ja ydin eivät rajaudu.

Vault ja lego ovat isännän verkossa, jotta Vault näkee agenttien todellisen IP:n. Siksi niiden
ulosmeno nojaa kerrokseen 2.

**Säännöt:**
```
root# /opt/acme/current/podman/scripts/install-host.sh install ... \
        --egress-allow 203.0.113.10:443,203.0.113.11:443 --dns 10.0.0.53,10.0.0.54
root# nft list table inet acme_egress
root# journalctl -k | grep acme-egress-drop
```
Säännöt ovat IP-pohjaisia. Jos DVV:n osoitteet muuttuvat, aja `install-host.sh install` uusilla
osoitteilla. **Älä kovakoodaa IP-osoitteita muualle.**

**Välityspalvelin (vaihtoehto):** aseta `.env`:iin `HTTPS_PROXY=http://proxy.sisainen:3128` ja salli
`--egress-allow <proxy-IP>:3128`. Välityspalvelimen allowlistille: DVV:n ACME-nimet. `NO_PROXY`
sisältää automaattisesti Vaultin osoitteen. TLS-tarkastavaa välityspalvelinta ei tueta.

**DNS:** keskus tarvitsee DVV:n nimien ratkaisun. Ilman välityspalvelinta ohjaa sisäisessä DNS:ssä
vain DVV:n vyöhyke (conditional forwarder) ulkoiseen resolveriin. Palvelimet tarvitsevat vain
Vaultin nimen.

**firewalld (sisääntulo):** `8080/tcp` kaikille (DNAT), `8200/tcp` rich rule: lähde `--server-cidrs`
→ kohde `--vault-ip`. Tarkistus: `install-host.sh check`.

## Todentaminen
```
acmesvc$ scripts/egress-check.sh
1. lego -> DVV (https://...)
  [OK]   DVV vastaa
2. lego -> muut kohteet (pitää olla estetty)
  [OK]   lego -> https://1.1.1.1/ estetty (curl 7)
  ...
3. nginx ja Vault -> ulos (pitää olla estetty)
  [OK]   acme-nginx -> https://1.1.1.1/ estetty (curl 7)
  [OK]   acme-vault -> https://1.1.1.1/ estetty (curl 7)
4. palvelukäyttäjä isännältä -> muut kohteet (nftables)
  ...
Tulos: verkkorajaukset kunnossa
```
Kohteita voi vaihtaa: `EGRESS_DENY_TARGETS="https://... https://..."`. Aja asennuksen ja jokaisen
verkkomuutoksen jälkeen. Kehitysympäristössä (ei nftablesia) skripti raportoi legon ja Vaultin
pääsyn ulos viaksi, kuten pitääkin.

## Palvelimet
Windows/Linux-palvelimille riittää TCP 8200 keskukseen. Online-sulkutarkistus tarvitsisi
yhteyden DVV:n CRL/OCSP-osoitteisiin, jota ilmaraossa ei ole: oletus `RevocationMode=NoCheck`
([windows-liittaminen.md](windows-liittaminen.md#9-tietoturvahuomiot)).
