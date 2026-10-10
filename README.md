# Tracciamento Percorso

App per iPhone che registra i tuoi viaggi con il GPS, **anche in background
e a schermo spento**, ed **evidenzia in arancione le strade già percorse**.
Così durante i viaggi puoi scegliere strade nuove.

## Funzioni

- **Avvia / Ferma**: registra il viaggio in corso (linea blu). Alla fine puoi
  dargli un nome, salvarlo o scartarlo.
- **Strade già percorse**: tutti i viaggi salvati sono disegnati in arancione;
  le strade fatte più volte risultano più intense.
- **Avviso**: se passi su una strada già fatta compare il banner
  "⚠️ Strada già percorsa" con vibrazione. Con l'app in background arriva una
  notifica (al massimo una al minuto). La distanza di avviso (15 / 25 / 40 m)
  è regolabile.
- **Tipo di mappa** (pulsante a destra con i livelli): standard, satellite con
  nomi delle strade, oppure solo satellite.
- **Ricerca indirizzo** (lente): suggerimenti mentre scrivi; il luogo scelto
  viene mostrato con un segnaposto rosso (tocca ✕ per toglierlo).
- **Nuove %**: quanta parte del viaggio attuale è su strade mai fatte.
- **Elenco viaggi**: zoom su un viaggio, eliminazione (scorri a sinistra),
  esportazione e importazione **GPX** (anche da Strava, Komoot, ecc.).
- I dati restano **solo sul telefono**, in `trips.json`, visibile anche
  dall'app File (*Sul mio iPhone → Percorso*). Esporta il GPX ogni tanto come
  backup.
- Se l'app viene chiusa durante un viaggio, alla riapertura la registrazione
  riprende.

## Installazione con Sideloadly

L'`.ipa` viene compilato automaticamente da GitHub Actions (serve un Mac, che
GitHub mette a disposizione) a ogni modifica della cartella `ios/`, dopo
aver eseguito i test automatici (`ios/PercorsoTests`).

1. Scarica l'ultima versione: **https://github.com/Kamizakinano/Tracciamento-Percorso/raw/ipa-build/Percorso.ipa**
   (viene pubblicata solo se i test automatici passano). In alternativa:
   scheda **Actions → Build iOS (IPA per Sideloadly)**, ultima esecuzione
   riuscita, artifact **Percorso-ipa**.
2. Apri **Sideloadly**, collega l'iPhone, trascina `Percorso.ipa`, inserisci il
   tuo Apple ID e premi **Start**.
3. Sull'iPhone: *Impostazioni → Generali → VPN e gestione dispositivi* →
   autorizza il tuo Apple ID. Su iOS 16+ attiva anche la
   **Modalità sviluppatore** (*Impostazioni → Privacy e sicurezza*).
4. Al primo **Avvia** consenti la posizione (**"Mentre usi l'app"** basta per
   il background) e le notifiche.

Con un Apple ID gratuito l'app scade dopo **7 giorni**: basta reinstallarla con
Sideloadly (i viaggi salvati restano se non la disinstalli).

### Come funziona il background

L'app dichiara la modalità background *location*: una volta avviata la
registrazione, iOS continua a inviare le posizioni anche con l'app chiusa nel
multitasking o lo schermo spento (in alto compare l'indicatore blu della
posizione). Se però chiudi l'app forzatamente (scorrendola via dal
multitasking) iOS ferma il GPS: riaprila e la registrazione riprende da dove
era rimasta.

## Struttura

| Percorso | Contenuto |
|---|---|
| `ios/project.yml` | Definizione del progetto Xcode (XcodeGen) |
| `ios/Percorso/LocationTracker.swift` | GPS in background, avvisi, salvataggio del viaggio in corso |
| `ios/Percorso/TripStore.swift` | Viaggi salvati e indice delle strade già fatte |
| `ios/Percorso/MapView.swift` | Mappa (Apple Maps) con i percorsi evidenziati |
| `ios/Percorso/ContentView.swift`, `TripsView.swift` | Interfaccia |
| `ios/Percorso/SearchView.swift` | Ricerca di indirizzi e luoghi |
| `ios/Percorso/GPX.swift` | Import/export GPX |
| `.github/workflows/ios.yml` | Compilazione dell'`.ipa` |
| `web/` | Prima versione come web app (senza background) |

Per compilare su un Mac: `brew install xcodegen && cd ios && xcodegen` e apri
`Percorso.xcodeproj`.
