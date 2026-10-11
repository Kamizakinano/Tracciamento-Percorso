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
  posizione **"Sempre"**. Per risparmiare batteria, dopo 5 minuti fermo l'app
  spegne il GPS e mette un "recinto" di 80 m intorno a te: quando ne esci iOS
  la risveglia e il GPS riparte (il tratto iniziale viene ricostruito lungo le
  strade). Se il GPS si ferma mentre ti stai muovendo (semaforo, coda,
  galleria), al risveglio il tratto mancante viene ricostruito lungo le strade
  invece di spezzare il viaggio.
- **Pulsante ∞ sulla mappa**: accende o spegne con un tocco la registrazione
  automatica (come "Registra sempre", funziona anche in background); verde =
  attiva. Anche toccando "Automatico" in basso puoi disattivarla.
- **Registra in un periodo** (impostazioni): scegli il giorno di inizio e di
  fine; in quei giorni ogni spostamento viene registrato da solo come con
  "Registra sempre", poi la registrazione si ferma. Notifica all'inizio e alla
  fine. Se l'app è chiusa del tutto parte al primo spostamento del primo giorno.
- **Colori per frequenza**: giallo = strada fatta 1 volta, arancione = 2-3
  volte, rosso = 4 o più. Il traffico di Apple (linee con le freccette) è spento di
  serie per non confondersi: si accende con "Mostra traffico" nel menu dei livelli.
- **Strade nuove vicino a te** (pulsante ✨): scarica le strade della zona da
  OpenStreetMap e mostra in verde tratteggiato quelle che non hai mai fatto.
  Si aggiorna quando sposti la mappa.
- **Ricerca "Dove vuoi andare?"** (lente): partenza (di solito "La mia
  posizione") e destinazione, suggerimenti vicini a te, luoghi recenti, scambio
  ⇅ e scelta del mezzo. Scelta la destinazione, l'app calcola i percorsi.
- **Tutti i negozi della zona**: scrivi per esempio "Lidl" (o "farmacia",
  "benzina"…) e premi Cerca, oppure usa le scorciatoie (Supermercati, Benzina,
  Farmacie, Bar, Ristoranti, Parcheggi, Bancomat): tutti i risultati compaiono
  sulla mappa e in un elenco ordinato per distanza; toccane uno per il percorso.
  Funziona con qualunque insegna o tipo di attività, in tutto il mondo (dati di
  Apple Mappe, ~25 risultati per ricerca). Spostando la mappa compare
  **"Cerca in questa zona"** per ripetere la ricerca nell'area visibile.
- **Percorso con più strade nuove**: l'app confronta i percorsi di Apple più due
  varianti e propone (in viola) quello con più strade nuove senza allungare
  troppo; con ‹ › vedi le alternative.
- **Riga dei mezzi** nella scheda del percorso: tempi con 🚗 auto, 🚲 bici
  (stima a ~16 km/h sul percorso pedonale: Apple non fornisce percorsi in bici
  alle app), 🚶 a piedi e 🚇 mezzi pubblici; tocca un mezzo per cambiare.
- **Mezzi pubblici** (bus, tram, metro, treni): itinerari da
  [Transitous](https://transitous.org) (gratuito, orari pubblici di gran parte
  d'Europa e oltre) con linee, colori, fermate e orari; "Dettagli" mostra dove
  salire e scendere. Se in una zona mancano i dati, "Apple Mappe" apre le
  indicazioni con i mezzi in Mappe.
- **Navigazione nell'app** (Avvia): prossima svolta con freccia e distanza,
  guida vocale in italiano, mappa 3D che ruota con la direzione, orario di
  arrivo, tempo e km rimanenti, ricalcolo automatico se esci dal percorso.
  La svolta compare anche nella Live Activity sul blocco schermo; il viaggio
  viene registrato e salvato come "Verso <destinazione>".
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
- **Parcheggio intelligente** (pulsante 🅿️ sulla mappa o menu ☰): quando un
  viaggio in auto finisce o prosegui a piedi, l'app salva da sola dove hai
  lasciato l'auto (serve che stia registrando: Avvia o "Registra sempre"); lo
  stesso quando l'iPhone si scollega da CarPlay o dal Bluetooth scelto come
  "auto". C'è anche "Ho parcheggiato qui". Sulla mappa compare l'auto 🚗 con la
  distanza; "Portami all'auto" avvia la navigazione a piedi. Puoi impostare la
  scadenza del ticket o del disco orario (notifica 5/10/15/30 minuti prima e
  conto alla rovescia nella Live Activity), una nota e una foto. Lo storico
  mostra tutti i parcheggi e, cercando una destinazione in auto, la scheda del
  percorso dice dove avevi già trovato posto in zona (segnaposto "P").
- **Passaporto e medaglie** (menu ☰): comuni, province, regioni e stati in cui
  sei passato (anche dai viaggi già registrati), con la data della prima
  visita. Medaglie a livelli (bronzo, argento, oro, platino) per comuni,
  province, regioni, stati, comuni nuovi in un giorno, km su strade nuove e
  viaggio più lungo, con la barra verso il prossimo traguardo. Notifica "Nuovo
  comune!" durante la registrazione e quando sblocchi una medaglia. I nomi dei
  luoghi vengono da Apple (serve internet; i viaggi lunghi richiedono qualche
  minuto).
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
| `ios/Percorso/SearchView.swift` | Ricerca partenza/destinazione |
| `ios/Percorso/NavigationSession.swift` | Navigazione svolta per svolta |
| `ios/Percorso/TransitPlanner.swift` | Mezzi pubblici (Transitous) |
| `ios/Percorso/GPX.swift` | Import/export GPX |
| `ios/Percorso/ExploreService.swift` | Strade nuove da OpenStreetMap |
| `ios/Percorso/RoutePlanner.swift` | Percorso con più strade nuove |
| `ios/Percorso/StatsView.swift` | Statistiche |
| `ios/Percorso/Passport.swift`, `PassportView.swift` | Passaporto dei luoghi e medaglie |
| `ios/Percorso/Parking.swift`, `ParkingView.swift` | Parcheggio: rilevamento, storico, ticket, Bluetooth |
| `ios/Percorso/BackupManager.swift` | Backup automatico |
| `ios/Percorso/VoiceAlert.swift`, `LiveActivityManager.swift` | Avviso vocale e Live Activity |
| `ios/LiveActivity/`, `ios/Shared/` | Estensione che disegna la Live Activity |
| `.github/workflows/ios.yml` | Compilazione dell'`.ipa` |
| `web/` | Prima versione come web app (senza background) |

Per compilare su un Mac: `brew install xcodegen && cd ios && xcodegen` e apri
`Percorso.xcodeproj`.
