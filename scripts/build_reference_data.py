#!/usr/bin/env python3
"""Build bundled airports.json + airlines.json for Arc.
Airports: mwgg/Airports (has IATA, ICAO, name, city, country, lat, lon, IANA tz).
Airlines: OpenFlights airlines.dat (IATA, ICAO, name, callsign, country, active).
Run once; commit the JSON outputs.
"""
import json, urllib.request, csv, io, os

OUT = os.path.join(os.path.dirname(__file__), "..", "Arc", "Resources")
os.makedirs(OUT, exist_ok=True)

# --- Airports ---
AIRPORTS_URL = "https://raw.githubusercontent.com/mwgg/Airports/master/airports.json"
raw = json.load(urllib.request.urlopen(AIRPORTS_URL))
airports = []
for icao, a in raw.items():
    iata = (a.get("iata") or "").strip()
    if len(iata) != 3:      # keep only real IATA-coded airports
        continue
    airports.append({
        "iata": iata,
        "icao": (a.get("icao") or "").strip(),
        "name": a.get("name") or "",
        "city": a.get("city") or "",
        "country": a.get("country") or "",   # ISO-2
        "lat": round(float(a.get("lat", 0)), 5),
        "lon": round(float(a.get("lon", 0)), 5),
        "tz": a.get("tz") or "",              # IANA, e.g. "Europe/Zurich"
    })
airports.sort(key=lambda x: x["iata"])
with open(os.path.join(OUT, "airports.json"), "w") as f:
    json.dump(airports, f, ensure_ascii=False, separators=(",", ":"))
print(f"airports: {len(airports)}")

# --- Airlines ---
AIRLINES_URL = "https://raw.githubusercontent.com/jpatokal/openflights/master/data/airlines.dat"
data = urllib.request.urlopen(AIRLINES_URL).read().decode("utf-8", "replace")
airlines = []
seen = set()
for row in csv.reader(io.StringIO(data)):
    # id,name,alias,iata,icao,callsign,country,active
    if len(row) < 8:
        continue
    name, iata, icao, callsign, country, active = row[1], row[3], row[4], row[5], row[6], row[7]
    iata = (iata or "").strip()
    if len(iata) != 2 or iata in ("-", "") or active != "Y":
        continue
    if iata in seen:        # first active wins
        continue
    seen.add(iata)
    airlines.append({
        "iata": iata,
        "icao": (icao or "").strip(),
        "name": name or "",
        "callsign": (callsign or "").strip(),
        "country": country or "",
    })
airlines.sort(key=lambda x: x["iata"])
with open(os.path.join(OUT, "airlines.json"), "w") as f:
    json.dump(airlines, f, ensure_ascii=False, separators=(",", ":"))
print(f"airlines: {len(airlines)}")
