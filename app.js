'use strict';

// ---------- Configurazione ----------
const STORAGE_KEY = 'tp_trips';
const CURRENT_KEY = 'tp_current';
const SETTINGS_KEY = 'tp_settings';
const MAX_ACCURACY_M = 50;      // scarta letture GPS troppo imprecise
const MIN_STEP_M = 5;           // ignora movimenti più piccoli (rumore GPS)
const CELL_DEG = 0.0007;        // lato cella dell'indice spaziale (~55-75 m)
const DENSIFY_STEP_M = 10;      // densità dei punti nell'indice
const HISTORY_STYLE = { color: '#ff7a00', weight: 9, opacity: 0.55 };
const CURRENT_STYLE = { color: '#1f6feb', weight: 5, opacity: 0.95 };

// ---------- Utilità ----------
function haversine(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b[0] - a[0]);
  const dLng = toRad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a[0])) * Math.cos(toRad(b[0])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function trackLength(points) {
  let d = 0;
  for (let i = 1; i < points.length; i++) d += haversine(points[i - 1], points[i]);
  return d;
}

function formatKm(m) {
  return (m / 1000).toLocaleString('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' km';
}

function load(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch (e) {
    return fallback;
  }
}

function save(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    console.warn('Salvataggio non riuscito', e);
  }
}

// ---------- Indice spaziale delle strade già percorse ----------
class SpatialIndex {
  constructor() { this.cells = new Map(); }

  key(lat, lng) {
    return Math.floor(lat / CELL_DEG) + ',' + Math.floor(lng / CELL_DEG);
  }

  addPoint(p) {
    const k = this.key(p[0], p[1]);
    let cell = this.cells.get(k);
    if (!cell) this.cells.set(k, (cell = []));
    cell.push(p);
  }

  // Aggiunge un tracciato inserendo punti intermedi, così anche tratti
  // registrati a velocità elevata (punti radi) vengono riconosciuti.
  addTrack(points) {
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      this.addPoint(p);
      if (i === 0) continue;
      const prev = points[i - 1];
      const d = haversine(prev, p);
      const steps = Math.floor(d / DENSIFY_STEP_M);
      for (let s = 1; s < steps; s++) {
        const f = s / steps;
        this.addPoint([prev[0] + (p[0] - prev[0]) * f, prev[1] + (p[1] - prev[1]) * f]);
      }
    }
  }

  isNear(p, thresholdM) {
    const ci = Math.floor(p[0] / CELL_DEG);
    const cj = Math.floor(p[1] / CELL_DEG);
    for (let di = -1; di <= 1; di++) {
      for (let dj = -1; dj <= 1; dj++) {
        const cell = this.cells.get((ci + di) + ',' + (cj + dj));
        if (!cell) continue;
        for (const q of cell) if (haversine(p, q) <= thresholdM) return true;
      }
    }
    return false;
  }
}

// ---------- Stato ----------
let trips = load(STORAGE_KEY, []);
let settings = Object.assign({ showHistory: true, alert: true, threshold: 25 }, load(SETTINGS_KEY, {}));
let current = load(CURRENT_KEY, null); // viaggio in corso (ripristinato se l'app è stata chiusa)
let index = new SpatialIndex();
let watchId = null;
let wakeLock = null;
let lastPos = null;
let onOldRoad = false;
let newRoadMeters = 0;
let followMe = true;

// ---------- Mappa ----------
const map = L.map('map', { preferCanvas: true, zoomControl: false }).setView([41.9, 12.5], 6);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; OpenStreetMap',
}).addTo(map);
L.control.zoom({ position: 'bottomright' }).addTo(map);

const historyLayer = L.layerGroup().addTo(map);
const currentLine = L.polyline([], CURRENT_STYLE).addTo(map);
const meMarker = L.marker([0, 0], {
  icon: L.divIcon({ className: '', html: '<div class="me-dot"></div>', iconSize: [22, 22] }),
});

map.on('dragstart', () => { followMe = false; });

// ---------- Elementi UI ----------
const $ = (id) => document.getElementById(id);
const btnTrack = $('btn-track');
const alertBox = $('alert');
const panel = $('panel');

function rebuildHistory() {
  historyLayer.clearLayers();
  index = new SpatialIndex();
  for (const t of trips) {
    index.addTrack(t.points);
    if (settings.showHistory && t.points.length > 1) {
      L.polyline(t.points.map((p) => [p[0], p[1]]), HISTORY_STYLE).addTo(historyLayer);
    }
  }
}

function fitAll() {
  const all = trips.flatMap((t) => t.points.map((p) => [p[0], p[1]]));
  if (all.length) map.fitBounds(L.latLngBounds(all), { padding: [40, 40] });
}

function updateStats() {
  const dist = current ? trackLength(current.points) : 0;
  $('stat-status').textContent = watchId !== null ? '● Registrazione' : 'Fermo';
  $('stat-distance').textContent = formatKm(dist);
  $('stat-new').textContent = dist > 0
    ? 'Nuove strade: ' + Math.round((newRoadMeters / dist) * 100) + '%'
    : 'Nuove strade: –';
}

function renderTripList() {
  const ul = $('trip-list');
  ul.innerHTML = '';
  if (!trips.length) {
    ul.innerHTML = '<li><small>Nessun viaggio salvato.</small></li>';
    return;
  }
  [...trips].reverse().forEach((t) => {
    const li = document.createElement('li');
    const info = document.createElement('div');
    const date = new Date(t.start).toLocaleString('it-IT', { dateStyle: 'medium', timeStyle: 'short' });
    info.innerHTML = '<strong></strong><small></small>';
    info.querySelector('strong').textContent = t.name || date;
    info.querySelector('small').textContent = date + ' · ' + formatKm(trackLength(t.points));
    const actions = document.createElement('div');
    const show = document.createElement('button');
    show.textContent = '🔍';
    show.title = 'Mostra sulla mappa';
    show.onclick = () => {
      if (t.points.length) map.fitBounds(L.latLngBounds(t.points.map((p) => [p[0], p[1]])), { padding: [40, 40] });
      panel.classList.add('hidden');
    };
    const del = document.createElement('button');
    del.textContent = '🗑';
    del.title = 'Elimina';
    del.onclick = () => {
      if (!confirm('Eliminare questo viaggio?')) return;
      trips = trips.filter((x) => x.id !== t.id);
      save(STORAGE_KEY, trips);
      rebuildHistory();
      renderTripList();
    };
    actions.append(show, del);
    li.append(info, actions);
    ul.append(li);
  });
}

function setAlert(on) {
  alertBox.classList.toggle('hidden', !(on && settings.alert));
  if (on && !onOldRoad && settings.alert && navigator.vibrate) navigator.vibrate([200, 100, 200]);
  onOldRoad = on;
}

// ---------- Tracciamento ----------
async function requestWakeLock() {
  try {
    if ('wakeLock' in navigator) wakeLock = await navigator.wakeLock.request('screen');
  } catch (e) { /* non supportato o negato */ }
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && watchId !== null) requestWakeLock();
});

function onPosition(pos) {
  const { latitude, longitude, accuracy } = pos.coords;
  const p = [latitude, longitude, pos.timestamp];

  meMarker.setLatLng([latitude, longitude]);
  if (!map.hasLayer(meMarker)) meMarker.addTo(map);
  if (followMe) map.setView([latitude, longitude], Math.max(map.getZoom(), 16));

  if (!current || accuracy > MAX_ACCURACY_M) return;
  if (lastPos && haversine(lastPos, p) < MIN_STEP_M) return;

  const near = index.isNear(p, settings.threshold);
  if (lastPos && !near) newRoadMeters += haversine(lastPos, p);
  setAlert(near);

  current.points.push(p);
  lastPos = p;
  currentLine.addLatLng([latitude, longitude]);
  save(CURRENT_KEY, current);
  updateStats();
}

function onError(err) {
  const msg = {
    1: 'Permesso di posizione negato. Abilitalo nelle impostazioni del browser.',
    2: 'Posizione non disponibile.',
    3: 'Timeout nel rilevare la posizione.',
  }[err.code] || err.message;
  alert(msg);
  if (err.code === 1) stopTracking(false);
}

function startTracking() {
  if (!('geolocation' in navigator)) {
    alert('Questo dispositivo non supporta la geolocalizzazione.');
    return;
  }
  if (!current) {
    current = { id: Date.now().toString(36), start: Date.now(), points: [] };
    newRoadMeters = 0;
  }
  lastPos = current.points[current.points.length - 1] || null;
  currentLine.setLatLngs(current.points.map((p) => [p[0], p[1]]));
  followMe = true;
  watchId = navigator.geolocation.watchPosition(onPosition, onError, {
    enableHighAccuracy: true,
    maximumAge: 0,
    timeout: 20000,
  });
  requestWakeLock();
  btnTrack.textContent = '■ Ferma';
  btnTrack.classList.add('recording');
  updateStats();
}

function stopTracking(keep = true) {
  if (watchId !== null) navigator.geolocation.clearWatch(watchId);
  watchId = null;
  if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
  if (current && keep && current.points.length > 1) {
    current.end = Date.now();
    const name = prompt('Nome del viaggio (facoltativo):', '');
    if (name) current.name = name.trim();
    trips.push(current);
    save(STORAGE_KEY, trips);
  }
  current = null;
  lastPos = null;
  try { localStorage.removeItem(CURRENT_KEY); } catch (e) { /* ignora */ }
  currentLine.setLatLngs([]);
  setAlert(false);
  rebuildHistory();
  renderTripList();
  updateStats();
  btnTrack.textContent = '▶ Avvia';
  btnTrack.classList.remove('recording');
}

// ---------- GPX ----------
function escapeXml(s) {
  return String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
}

function toGpx(list) {
  const trks = list.map((t) => {
    const pts = t.points.map((p) =>
      `<trkpt lat="${p[0]}" lon="${p[1]}">${p[2] ? `<time>${new Date(p[2]).toISOString()}</time>` : ''}</trkpt>`
    ).join('');
    return `<trk><name>${escapeXml(t.name || new Date(t.start).toISOString())}</name><trkseg>${pts}</trkseg></trk>`;
  }).join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="Tracciamento Percorso" xmlns="http://www.topografix.com/GPX/1/1">\n${trks}\n</gpx>`;
}

function fromGpx(text) {
  const doc = new DOMParser().parseFromString(text, 'application/xml');
  if (doc.querySelector('parsererror')) throw new Error('File GPX non valido');
  const result = [];
  doc.querySelectorAll('trk, rte').forEach((trk, i) => {
    const pts = [...trk.querySelectorAll('trkpt, rtept')].map((el) => {
      const time = el.querySelector('time');
      return [parseFloat(el.getAttribute('lat')), parseFloat(el.getAttribute('lon')), time ? Date.parse(time.textContent) : 0];
    }).filter((p) => isFinite(p[0]) && isFinite(p[1]));
    if (pts.length < 2) return;
    const name = trk.querySelector(':scope > name');
    result.push({
      id: Date.now().toString(36) + '-' + i + '-' + Math.random().toString(36).slice(2, 6),
      start: pts[0][2] || Date.now(),
      end: pts[pts.length - 1][2] || Date.now(),
      name: name ? name.textContent : undefined,
      points: pts,
    });
  });
  return result;
}

function download(filename, text) {
  const blob = new Blob([text], { type: 'application/gpx+xml' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

// ---------- Eventi UI ----------
btnTrack.onclick = () => (watchId === null ? startTracking() : stopTracking());

$('btn-center').onclick = () => {
  followMe = true;
  if (map.hasLayer(meMarker)) {
    map.setView(meMarker.getLatLng(), Math.max(map.getZoom(), 16));
  } else if ('geolocation' in navigator) {
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        meMarker.setLatLng([pos.coords.latitude, pos.coords.longitude]).addTo(map);
        map.setView([pos.coords.latitude, pos.coords.longitude], 16);
      },
      onError,
      { enableHighAccuracy: true, timeout: 20000 }
    );
  }
};

$('btn-menu').onclick = () => { renderTripList(); panel.classList.remove('hidden'); };
$('btn-close').onclick = () => panel.classList.add('hidden');

$('chk-history').checked = settings.showHistory;
$('chk-history').onchange = (e) => {
  settings.showHistory = e.target.checked;
  save(SETTINGS_KEY, settings);
  rebuildHistory();
};

$('chk-alert').checked = settings.alert;
$('chk-alert').onchange = (e) => {
  settings.alert = e.target.checked;
  save(SETTINGS_KEY, settings);
  setAlert(onOldRoad);
};

$('sel-threshold').value = String(settings.threshold);
$('sel-threshold').onchange = (e) => {
  settings.threshold = Number(e.target.value);
  save(SETTINGS_KEY, settings);
};

$('btn-export').onclick = () => {
  if (!trips.length) return alert('Nessun viaggio da esportare.');
  download('percorsi-' + new Date().toISOString().slice(0, 10) + '.gpx', toGpx(trips));
};

$('file-import').onchange = async (e) => {
  let added = 0;
  for (const file of e.target.files) {
    try {
      const imported = fromGpx(await file.text());
      trips.push(...imported);
      added += imported.length;
    } catch (err) {
      alert(file.name + ': ' + err.message);
    }
  }
  e.target.value = '';
  if (added) {
    save(STORAGE_KEY, trips);
    rebuildHistory();
    renderTripList();
    fitAll();
  }
};

// ---------- Avvio ----------
rebuildHistory();
updateStats();
if (current && current.points.length) {
  // L'app era stata chiusa durante un viaggio: riprendi la registrazione.
  newRoadMeters = 0;
  startTracking();
} else {
  current = null;
  fitAll();
}

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js').catch(() => {});
}
