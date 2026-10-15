# Dolly

App Mac di regia di proiezione per il cinema: mpv a schermo intero (senza controlli) sullo schermo della sala, controlli nativi (SwiftUI) sull'altro schermo.

- `swift/` — l'app: `Engine.swift` (sequenza, neri, intervalli, riavvio di mpv), `Mpv.swift` (processo + socket IPC), `UI.swift` (SwiftUI a tre colonne, schede, niente accordion), `Preview.swift` (anteprima fluida con ScreenCaptureKit), `App.swift` (finestra, menu, schermo), `TestServer.swift` (interfaccia di collaudo, solo con `--test-api`).
- `build_app.sh` — produce `dist/Dolly Projector.app` e `dist/Dolly-Projector.zip` (universale arm64+x86_64) con **due** mpv dentro: `mpv-arm64.app` (nativo, per Apple Silicon: parte in ~0,5 s) e `mpv-x86_64.app` (Mac Intel). Servono `/Applications/mpv.app` (x86_64), `vendor/mpv-arm64.app` (da laboratory.stolendata.net/~djinn/mpv_osx/mpv-arm64-latest.tar.gz, fuori da git) e l'SDK 15.2 del CommandLineTools.
- `test_dolly.py` — 104 controlli sull'app vera: `DOLLY_BIN=dist/Dolly\ Projector.app/Contents/MacOS/Dolly ./test_dolly.py CARTELLA_MEDIA` (vedi l'intestazione per i file di prova; `-k soak --soak 10`, `--real FILM…`).
- `icon/` — icona (generata con Codex: `Dolly-1024.png`, `Dolly.icns`, script `genera_icone.py`).
- `legacy/` — prima versione (motore Python + interfaccia web), tenuta come riferimento.
- Aspetto senza aprire finestre: `Dolly --snapshot out.png --folder CARTELLA --play 1`.

## Scaletta: avvio senza cartella e selezione multipla
- La **cartella dei film è facoltativa**: all'avvio l'app non la chiede, parte con la scaletta vuota e i film si aggiungono dal pulsante + o trascinandoli. La cartella si sceglie quando serve (scheda Scena → *Scegli…*, o menu): la prima volta la scaletta già costruita resta com'è; cambiandola dopo, la scaletta riparte dai film della nuova cartella.
- **Selezione multipla**: clic seleziona, ⌘+clic (Ctrl su Windows) aggiunge o toglie, Maiusc+clic seleziona un intervallo, ⌘A (Ctrl+A) tutto, Esc deseleziona. Sulla selezione: Canc toglie gli elementi (con conferma), il menu del clic destro li sposta su/giù, trascinare la maniglia di un elemento selezionato sposta tutto il blocco, e le impostazioni di uno dei selezionati (icona a destra) valgono per tutti.
- Motore: azioni `removemany` (`indices`) e `reordermany` (`from`, `to`, `after`); test `-k multi,nofolder`.

## DCP (cinema digitale)
Dolly proietta i **DCP non cifrati**: Aggiungi → *DCP (cartella)…* (o trascina la cartella del pacchetto nella scaletta; si può anche aggiungere un singolo file CPL, o mettere i DCP come sottocartelle della cartella dei film: compaiono nella libreria). Un pacchetto con più versioni (più CPL) dà un elemento per versione.
- Dal CPL si costruisce per mpv una lista di montaggio (EDL) con un flusso video (JPEG 2000, spazio colore XYZ, che mpv converte da solo) e uno audio (PCM 24 bit, 5.1) che attraversano tutti i reel senza interruzioni; seek, riprendi, ripeti e intervalli funzionano come per un film normale.
- Sottotitoli di testo (Interop in XML e SMPTE dentro l'MXF) → un SRT con i tempi dell'intera sequenza, nella cache `~/Library/Application Support/Dolly/dcp-cache`; si accendono e si stilizzano come gli altri.
- **Non** supportati: DCP cifrati (serve una KDM per il certificato di un lettore: Dolly lo dice e passa oltre), 3D, sottotitoli a immagini (PNG), audio oltre il 5.1, pacchetti Supplemental/VF a cui manchi l'OV.
- La decodifica JPEG 2000 è software: va bene su un Mac recente per un 2K, su un Mac vecchio (come un mini Intel del 2018) può non reggere i 24 fotogrammi/s; in quel caso convertire il DCP (per esempio con DCP-o-matic) in un mkv.
- Collaudo: `tools/make_test_dcp.py DIR` crea DCP di prova (servono ffmpeg e `asdcp-test` di asdcplib, con il supporto XML); poi `DOLLY_DCP_DIR=DIR ./test_dolly.py MEDIA -k dcp`.

## Intervalli
- **Intervallo a metà film**: nelle impostazioni del film, "Intervallo a (min)" + durata e testo. Il film si ferma a quel minuto, la sala mostra testo e conto alla rovescia, poi riparte da lì.
- **Sfondo** (immagine o video in loop, audio opzionale) e **preset** (sfondo, testo, durata; in `~/Library/Application Support/Dolly/presets.json`) per ogni intervallo.

## Telecomando dal telefono
Scheda **Altro → Telecomando dal telefono**: attivando l'interruttore l'app apre un piccolo server sulla rete locale (porta 8484, spento di default). Il telefono inquadra il QR o apre l'indirizzo, inserisce il PIN (4 cifre, in `~/Library/Application Support/Dolly/remote.json`) e comanda play/pausa, precedente/successivo, tempo, volume, muto, ripeti film, scena e intervalli. Non serve internet, solo una rete comune (router, hotspot…).
- Solo i comandi elencati in `allowed` (`Remote.swift`) sono accettati: niente cartelle, file, scalette o impostazioni dell'app.
- Cinque PIN sbagliati in un minuto bloccano i nuovi accessi; "Nuovo PIN" scollega i telefoni già abilitati.
- La pagina è `RemoteHTML.swift` (un file, nessuna richiesta esterna).
- Collaudo: `./test_dolly.py MEDIA -k remote` (avvia l'app con `--remote`).

## Lingua (italiano / inglese)
L'interfaccia segue la lingua del sistema (italiano se è italiano, altrimenti inglese); dal menu **Dolly Projector → Lingua** si può scegliere Automatica / Italiano / English. Tutti i testi stanno in `swift/L10n.swift` (chiave = italiano, valore = inglese) e passano da `tr()` / `trf()` (formato con %@ e %d). Per un nuovo testo: scriverlo in italiano nel codice dentro `tr("…")` e aggiungere la riga inglese in `L10n.swift` (se manca resta l'italiano). Anche la pagina del telecomando si traduce. `DOLLY_LANG=it|en` forza la lingua (i collaudi usano `it`); screenshot per il sito: `DOLLY_LANG=en DOLLY_DARK=1 DOLLY_CLEAN=1 Dolly --snapshot out.png --folder CARTELLA --play N --wait 6 --size 1240x720`.

