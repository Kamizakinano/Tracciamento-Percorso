# Tracciamento Percorso

Web app (installabile sul telefono) che registra i tuoi viaggi con il GPS ed
**evidenzia in arancione le strade già percorse**, così durante i viaggi puoi
scegliere strade nuove.

## Funzioni

- **▶ Avvia / ■ Ferma**: registra il viaggio in corso (linea blu).
- **Strade già percorse**: tutti i viaggi salvati sono disegnati in arancione;
  le strade fatte più volte risultano più intense.
- **Avviso**: se passi su una strada già fatta compare il banner
  "⚠️ Strada già percorsa" e il telefono vibra. La distanza di avviso
  (15 / 25 / 40 m) è regolabile.
- **Nuove strade %**: quanta parte del viaggio attuale è su strade mai fatte.
- **☰ Viaggi salvati**: elenco, zoom su un viaggio, eliminazione,
  esportazione e importazione **GPX** (anche da altre app come Strava o Komoot).
- I dati restano **solo sul tuo dispositivo** (memoria del browser): esporta
  il GPX ogni tanto come backup.
- Se il browser si chiude durante un viaggio, alla riapertura la registrazione
  riprende.

## Come usarla sul telefono

Il GPS nel browser funziona solo con HTTPS, quindi il modo più semplice è
pubblicarla con **GitHub Pages**:

1. Su GitHub: *Settings → Pages → Build and deployment*, *Source: Deploy from a
   branch*, scegli il branch e la cartella `/ (root)`.
2. Apri l'indirizzo `https://<utente>.github.io/Tracciamento-Percorso/` dal
   telefono e consenti l'accesso alla posizione.
3. Dal menu del browser scegli **"Aggiungi a schermata Home"** per usarla come
   un'app.

## Limiti da sapere

- Le app web **non registrano con lo schermo spento** o con il browser in
  background. Per questo l'app tiene lo schermo acceso durante la
  registrazione (dove il browser lo supporta). Per tracciare in background
  servirebbe un'app nativa (Android/iOS): si può fare in un secondo momento.
- La mappa (OpenStreetMap) richiede la connessione internet.

## Struttura

| File | Contenuto |
|---|---|
| `index.html` | Interfaccia |
| `style.css` | Stile (chiaro/scuro automatico) |
| `app.js` | GPS, salvataggio, rilevamento strade già percorse, GPX |
| `sw.js`, `manifest.json` | Installazione come app e funzionamento offline |
| `vendor/leaflet/` | Libreria mappe [Leaflet](https://leafletjs.com) 1.9.4 (licenza BSD-2) |

Per provarla sul computer: `python3 -m http.server` nella cartella e apri
`http://localhost:8000`.
