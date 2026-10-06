#!/usr/bin/env bash
# /usr/local/sbin/install-cert.sh  (root:root 0755)
# Tarkistaa agentin hakemat varmenteet ja asentaa vain hyväksytyt.
# Epäonnistuessa vanha varmenne jää voimaan ja palvelu jatkaa normaalisti.
set -euo pipefail
umask 077
source /etc/cert-install.conf
log(){ logger -t cert-install -p "auth.$1" "$2"; echo "$2"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
install -d -m 0750 -o root -g root "$TARGET"
CHANGED=()

for SRC in "$STAGING"/*.pem; do
  [[ -e "$SRC" ]] || continue
  NAME=$(basename "$SRC" .pem)
  [[ "$NAME" =~ ^[a-z0-9-]+$ ]] || { log err "$NAME: virheellinen nimi, ohitetaan"; continue; }
  DST="$TARGET/$NAME.pem"
  cmp -s "$SRC" "$DST" 2>/dev/null && continue            # ei muutosta

  # Kopioi ensin root-omisteiseen työhakemistoon (ei TOCTOU-kisaa agentin kanssa)
  cp "$SRC" "$WORK/$NAME.pem"; F="$WORK/$NAME.pem"
  # Pilko varmenteet: 1. = palvelinvarmenne, loput = välivarmenteet
  # (vain CERTIFICATE-lohkot; avainlohko ei päädy ketjutiedostoihin)
  awk -v d="$WORK/$NAME" '/-----BEGIN CERTIFICATE-----/{n++; inb=1} inb{print > (d"-cert"n".pem")} /-----END CERTIFICATE-----/{inb=0}' "$F"
  LEAF="$WORK/$NAME-cert1.pem"
  [[ -s "$LEAF" ]] || { log err "$NAME: varmenne puuttuu"; continue; }
  UNTRUSTED=()
  if compgen -G "$WORK/$NAME-cert[2-9]*.pem" >/dev/null; then
    cat "$WORK/$NAME"-cert[2-9]*.pem > "$WORK/$NAME-chain.pem"
    UNTRUSTED=(-untrusted "$WORK/$NAME-chain.pem")
  fi

  # 1) Avain vastaa varmennetta
  if ! diff -q <(openssl x509 -in "$LEAF" -noout -pubkey) \
               <(openssl pkey -in "$F" -pubout 2>/dev/null) >/dev/null; then
    log err "$NAME: avain ei vastaa varmennetta, hylätään"; continue
  fi
  # 2) Ketju validoituu DVV:n CA:han (tarkistaa myös voimassaoloajat)
  if ! openssl verify -CAfile "$DVV_CA" "${UNTRUSTED[@]}" -purpose sslserver "$LEAF" >/dev/null 2>&1; then
    log err "$NAME: ketju ei validoidu DVV:n CA:han, hylätään"; continue
  fi
  # 3) Riittävästi voimassaoloaikaa jäljellä
  if ! openssl x509 -in "$LEAF" -noout -checkend "$MIN_VALID_SECONDS" >/dev/null; then
    log err "$NAME: vanhenee pian, hylätään"; continue
  fi
  # 4) Ei vanhempi kuin nykyinen (estää palautushyökkäyksen vanhaan varmenteeseen)
  if [[ -e "$DST" ]]; then
    NEW=$(date -d "$(openssl x509 -in "$LEAF" -noout -enddate | cut -d= -f2)" +%s)
    OLD=$(date -d "$(openssl x509 -in "$DST"  -noout -enddate | cut -d= -f2)" +%s)
    (( NEW >= OLD )) || { log err "$NAME: uusi varmenne on vanhempi kuin nykyinen, hylätään"; continue; }
    cp -p "$DST" "$DST.prev"
  fi

  # Atominen asennus: kirjoitus samaan hakemistoon + rename
  install -m 0600 -o root -g root "$F" "$DST.new" && mv -f "$DST.new" "$DST"
  CHANGED+=("$NAME")
  log info "$NAME: asennettu, voimassa $(openssl x509 -in "$LEAF" -noout -enddate | cut -d= -f2) asti"
done

(( ${#CHANGED[@]} )) || exit 0

if $TEST_CMD >/dev/null 2>&1; then
  $RELOAD_CMD && log info "Palvelu ladattu uudelleen: ${CHANGED[*]}"
else
  log crit "Konfiguraatiotesti epäonnistui, palautetaan edelliset: ${CHANGED[*]}"
  for N in "${CHANGED[@]}"; do
    [[ -e "$TARGET/$N.pem.prev" ]] && mv -f "$TARGET/$N.pem.prev" "$TARGET/$N.pem"
  done
  exit 1
fi
