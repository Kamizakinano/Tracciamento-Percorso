# Tracciamento Percorso

App per iPhone che registra i tuoi viaggi con il GPS, **anche in background
e a schermo spento**, ed **evidenzia in arancione le strade già percorse**.
Così durante i viaggi puoi scegliere strade nuove.

## Funzioni

- **Avvia / Ferma**: registra un viaggio (linea blu). Alla fine puoi dargli un
  nome, salvarlo o scartarlo.
- **Registra sempre** (impostazioni): registrazione automatica senza premere
  Avvia, anche con l'app chiusa. Ogni spostamento diventa un viaggio (si chiude
  dopo 5 minuti fermo, a un salto di 2 km o a mezzanotte). Serve il permesso di
  posizione **"Sempre"**; quando sei fermo iOS sospende il GPS per risparmiare
  batteria.
- **Colori per frequenza**: giallo = strada fatta 1 volta, arancione = 2-3
  volte, rosso = 4 o più.
- **Strade nuove vicino a te** (pulsante ✨): scarica le strade della zona da
  OpenStreetMap e mostra in verde tratteggiato quelle che non hai mai fatto.
  Si aggiorna quando sposti la mappa.
- **Percorso con più strade nuove**: cerca un indirizzo, tocca l'icona viola
  accanto al nome. L'app confronta i percorsi di Apple più due varianti e
  propone (in viola) quello con più strade nuove senza allungare troppo;
  con ‹ › vedi le alternative. "Naviga con Mappe" apre la navigazione verso la
  destinazione (Mappe calcola il suo percorso).
- **Mezzo**: auto, bici, a piedi o rilevamento automatico dalla velocità.
  Cambia la distanza di avviso (25 / 18 / 12 m), la precisione del GPS e le
  strade proposte.
- **Filtri**: considera solo i viaggi degli ultimi 12 / 6 mesi / 30 giorni e/o
  di un solo mezzo (vale per mappa e avvisi).
- **Avvisi**: banner e vibrazione con l'app aperta, notifica in background,
  **avviso vocale** "Strada già percorsa" (mai / solo con cuffie o CarPlay /
  sempre).
- **Live Activity** sul blocco schermo e nella Dynamic Island durante la
  registrazione: km, tempo, % di strade nuove e avviso. iOS permette di
  avviarla solo con l'app aperta.
- **Statistiche**: km, tempo, km su strade nuove, divisione per mezzo, zone più
  esplorate, per settimana / mese / anno / sempre.
- **Backup automatico**: scegli una cartella (per esempio in iCloud Drive) e a
  ogni viaggio salvato viene aggiornato `Percorso-backup.json`; "Ripristina da
  backup" lo ricarica. Funziona anche con un Apple ID gratuito.
- **Mappa**: standard, satellite con strade o solo satellite; ricerca di
  indirizzi; import/export **GPX**.

## Installazione con Sideloadly

L'`.ipa` viene compilato automaticamente da GitHub Actions (serve un Mac, che
GitHub mette a disposizione) a ogni modifica della cartella `ios/`, dopo
aver eseguito i test automatici (`ios/PercorsoTests`).

1. Scarica l'ultima versione dal branch
   [`ipa-build`](https://github.com/Kamizakinano/Tracciamento-Percorso/tree/ipa-build):
   il file si chiama **`Percorso-v<versione>.ipa`** (es. `Percorso-v1.2.7.ipa`).
   Viene pubblicato solo se i test automatici passano. In alternativa: scheda
   **Actions → Build iOS (IPA per Sideloadly)**, ultima esecuzione riuscita.

   La versione è `principale.compilazione`: la parte principale (in
   `ios/project.yml`) sale con le funzioni nuove, l'ultimo numero cresce a ogni
   compilazione. La versione installata si legge in fondo alla schermata ☰.
2. Apri **Sideloadly**, collega l'iPhone, trascina il file `.ipa`, inserisci il
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
| `ios/Percorso/ExploreService.swift` | Strade nuove da OpenStreetMap |
| `ios/Percorso/RoutePlanner.swift` | Percorso con più strade nuove |
| `ios/Percorso/StatsView.swift` | Statistiche |
| `ios/Percorso/BackupManager.swift` | Backup automatico |
| `ios/Percorso/VoiceAlert.swift`, `LiveActivityManager.swift` | Avviso vocale e Live Activity |
| `ios/LiveActivity/`, `ios/Shared/` | Estensione che disegna la Live Activity |
| `.github/workflows/ios.yml` | Compilazione dell'`.ipa` |
| `web/` | Prima versione come web app (senza background) |

Per compilare su un Mac: `brew install xcodegen && cd ios && xcodegen` e apri
`Percorso.xcodeproj`.
