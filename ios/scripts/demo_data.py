#!/usr/bin/env python3
"""Crea viaggi di prova su strade vere di Milano (percorsi calcolati con OSRM)
per gli screenshot del simulatore. Uso: demo_data.py <cartella di uscita>"""
import json, math, os, sys, time, urllib.request, uuid

OUT = sys.argv[1]
APPLE_EPOCH = 978307200  # le Date di Swift sono secondi dal 2001-01-01

ROUTES = [
    ("Duomo → Stazione Centrale", (45.4642, 9.1900), (45.4859, 9.2048)),
    ("Castello → Porta Romana", (45.4705, 9.1795), (45.4515, 9.2030)),
    ("Navigli → Città Studi", (45.4520, 9.1735), (45.4780, 9.2270)),
]


def osrm(a, b):
    url = ("https://router.project-osrm.org/route/v1/driving/"
           f"{a[1]},{a[0]};{b[1]},{b[0]}?overview=full&geometries=geojson")
    with urllib.request.urlopen(url, timeout=20) as r:
        coords = json.load(r)["routes"][0]["geometry"]["coordinates"]
    return [(lat, lon) for lon, lat in coords]


def straight(a, b, n=60):
    return [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(n + 1)]


def points(coords, start):
    return [{"lat": lat, "lon": lon, "time": start - APPLE_EPOCH + i * 4} for i, (lat, lon) in enumerate(coords)]


os.makedirs(OUT, exist_ok=True)
now = time.time()
trips, first = [], None
for day, (name, a, b) in enumerate(ROUTES, start=1):
    try:
        coords = osrm(a, b)
    except Exception as e:  # senza rete: linea retta
        print(f"OSRM non disponibile ({e}), uso una linea retta", file=sys.stderr)
        coords = straight(a, b)
    first = first or coords
    start = now - day * 86400
    trips.append({"id": str(uuid.uuid4()).upper(), "name": name,
                  "start": start - APPLE_EPOCH, "end": start - APPLE_EPOCH + len(coords) * 4,
                  "points": points(coords, start)})

with open(f"{OUT}/trips.json", "w") as f:
    json.dump(trips, f)

# Viaggio in corso: prima parte del primo percorso (strada già fatta).
k = max(2, int(len(first) * 0.6))
here = first[min(k + 2, len(first) - 1)]
with open(f"{OUT}/current.json", "w") as f:
    json.dump({"start": now - 900 - APPLE_EPOCH, "points": points(first[:k], now - 900)}, f)
with open(f"{OUT}/here.txt", "w") as f:
    f.write(f"{here[0]},{here[1]}")
with open(f"{OUT}/home.txt", "w") as f:
    f.write("45.4642,9.1900")
print(f"{len(trips)} viaggi, viaggio in corso di {k} punti")
