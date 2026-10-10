#!/bin/bash
# Verifica il formato e la copertura dell'API di Transitous (mezzi pubblici).
UA='Percorso iOS (uso personale)'
T=$(date -u -d 'next monday 08:00' +%Y-%m-%dT%H:%M:%SZ)
for v in v1 v2 v3 v4 v5; do
  code=$(curl -s -o /tmp/p.json -w '%{http_code}' -m 40 -A "$UA" \
    "https://api.transitous.org/api/$v/plan?fromPlace=45.4642,9.1900&toPlace=45.4859,9.2048&time=$T")
  echo "== api/$v/plan Milano -> HTTP $code, $(wc -c < /tmp/p.json) byte"
done
for v in v1 v5; do
  curl -s -m 40 -A "$UA" "https://api.transitous.org/api/$v/plan?fromPlace=45.4642,9.1900&toPlace=45.4859,9.2048&time=$T" -o /tmp/p.json
  echo "== Struttura api/$v (Milano Duomo -> Centrale)"
  jq -c 'keys' /tmp/p.json 2>/dev/null
  jq -c '.itineraries[0] | del(.legs)' /tmp/p.json 2>/dev/null | head -c 800; echo
  jq -c '.itineraries[0].legs[] | del(.intermediateStops) | .legGeometry.points |= (.[0:40])' /tmp/p.json 2>/dev/null | head -c 4000; echo
  jq -c '.itineraries[0].legs[] | select(.intermediateStops) | .intermediateStops[0]' /tmp/p.json 2>/dev/null | head -c 600; echo
done
echo "== Copertura (api/v1, numero di itinerari e linee del primo)"
while read -r name from to; do
  curl -s -m 40 -A "$UA" "https://api.transitous.org/api/v1/plan?fromPlace=$from&toPlace=$to&time=$T" -o /tmp/c.json
  n=$(jq '.itineraries | length' /tmp/c.json 2>/dev/null)
  lines=$(jq -r '[.itineraries[0].legs[] | select(.mode != "WALK") | "\(.mode) \(.routeShortName // "")"] | join(", ")' /tmp/c.json 2>/dev/null)
  echo "$name: $n itinerari — $lines"
done <<'LIST'
Milano 45.4642,9.1900 45.4859,9.2048
Roma 41.9009,12.5016 41.8902,12.4922
Torino 45.0703,7.6869 45.0622,7.6780
Napoli 40.8529,14.2681 40.8399,14.2500
Palermo 38.1157,13.3615 38.1320,13.3410
Berlino 52.5251,13.3694 52.5163,13.3777
Parigi 48.8809,2.3553 48.8584,2.2945
Madrid 40.4065,-3.6895 40.4168,-3.7038
Vienna 48.1855,16.3769 48.2082,16.3738
Amsterdam 52.3791,4.9003 52.3600,4.8852
Varsavia 52.2289,21.0032 52.2297,21.0122
LIST
