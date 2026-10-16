#!/bin/bash
# Screenshot reali dell'app nel simulatore iOS, con viaggi di prova.
# Uso: screenshots.sh <udid simulatore> <Percorso.app per simulatore> <cartella di uscita>
set -euo pipefail
UDID="$1"; APP="$2"; OUT="$3"
BUNDLE=com.kamizakinano.percorso
DIR="$(cd "$(dirname "$0")" && pwd)"
DEMO="$(mktemp -d)"

mkdir -p "$OUT"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE" || xcrun simctl privacy "$UDID" grant location "$BUNDLE"

python3 "$DIR/demo_data.py" "$DEMO"
DOCS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents"
mkdir -p "$DOCS"
cp "$DEMO/trips.json" "$DOCS/"

stop_app() { xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true; sleep 1; }
map_style() { xcrun simctl spawn "$UDID" defaults write "$BUNDLE" mapStyle -int "$1"; }
shot() {
  local name="$1"; shift
  stop_app
  xcrun simctl launch "$UDID" "$BUNDLE" -screenshots "$@" >/dev/null
  sleep 15  # tempo per caricare le mappe
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
  echo "Salvato $name.png"
}

xcrun simctl location "$UDID" set "$(cat "$DEMO/home.txt")"
map_style 0
shot 1-mappa

# Registrazione in corso su una strada già fatta (l'app riprende il viaggio salvato).
cp "$DEMO/current.json" "$DOCS/"
xcrun simctl location "$UDID" set "$(cat "$DEMO/here.txt")"
shot 2-registrazione
stop_app
rm -f "$DOCS/current.json"
xcrun simctl location "$UDID" set "$(cat "$DEMO/home.txt")"

map_style 1
shot 3-satellite
map_style 0

shot 4-strade-nuove -explore
sleep 15 && xcrun simctl io "$UDID" screenshot "$OUT/4-strade-nuove.png"  # attende OpenStreetMap
shot 5-percorso -routeTo "45.4859,9.2048,Stazione Centrale"
sleep 10 && xcrun simctl io "$UDID" screenshot "$OUT/5-percorso.png"     # attende i percorsi di Apple
shot 6-statistiche -stats
shot 7-impostazioni -showTrips
shot 8-ricerca -search "Duomo di Milano"
shot 11-negozi -searchAll "Lidl"
sleep 8 && xcrun simctl io "$UDID" screenshot "$OUT/11-negozi.png"  # attende i risultati
shot 12-cerca-zona -searchAll "Lidl" -panAfter
sleep 10 && xcrun simctl io "$UDID" screenshot "$OUT/12-cerca-zona.png"  # dopo lo spostamento della mappa
# Parcheggio (dati di prova: auto vicino al Duomo con ticket, storico vicino alla Stazione Centrale).
shot 13-parcheggio-mappa -parkDemo
shot 14-parcheggio-scheda -parkDemo -showParking
shot 15-parcheggio-storico -parkDemo -parkingHistory
shot 16-parcheggio-zona -parkDemo -routeTo "45.4859,9.2048,Stazione Centrale"
sleep 10 && xcrun simctl io "$UDID" screenshot "$OUT/16-parcheggio-zona.png"  # attende i percorsi di Apple
stop_app
rm -rf "$DOCS/parking.json" "$DOCS/Parcheggi"  # gli altri screenshot senza auto parcheggiata

# Scopri: monumenti vicino a te (dati di prova, senza rete).
shot 22-scopri -discoverDemo

# Passaporto e medaglie (dati di prova).
shot 19-passaporto -passportDemo -showTrips -showPassport
shot 20-passaporto-luoghi -passportDemo -showTrips -showPassport -passportPlaces
shot 21-passaporto-km -passportDemo -showTrips -showPassport -passportKm
rm -f "$DOCS/passport.json"

# Registrazione programmata (in fondo: poi viene spenta).
shot 17-periodo -periodDemo -showTrips
shot 18-periodo-mappa -periodDemo
stop_app
xcrun simctl spawn "$UDID" defaults write "$BUNDLE" periodOn -bool false
shot 10-mezzi -routeTo "45.4859,9.2048,Stazione Centrale" -transit
sleep 12 && xcrun simctl io "$UDID" screenshot "$OUT/10-mezzi.png"  # attende Transitous
shot 9-navigazione -routeTo "45.4859,9.2048,Stazione Centrale" -navigate
sleep 12 && xcrun simctl io "$UDID" screenshot "$OUT/9-navigazione.png"  # attende l'avvio della navigazione
stop_app
