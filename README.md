# Dolly

App Mac di regia di proiezione per il cinema: mpv a schermo intero (senza controlli) sullo schermo della sala, controlli nativi (SwiftUI) sull'altro schermo.

- `swift/` — l'app: `Engine.swift` (sequenza, neri, intervalli, riavvio di mpv), `Mpv.swift` (processo + socket IPC), `UI.swift` (SwiftUI a tre colonne, schede, niente accordion), `Preview.swift` (anteprima fluida con ScreenCaptureKit), `App.swift` (finestra, menu, schermo), `TestServer.swift` (interfaccia di collaudo, solo con `--test-api`).
- `build_app.sh` — produce `dist/Dolly Projector.app` e `dist/Dolly-Projector.zip` (universale arm64+x86_64, mpv incluso). Serve `/Applications/mpv.app` x86_64 e l'SDK 15.2 del CommandLineTools.
- `test_dolly.py` — 104 controlli sull'app vera: `DOLLY_BIN=dist/Dolly\ Projector.app/Contents/MacOS/Dolly ./test_dolly.py CARTELLA_MEDIA` (vedi l'intestazione per i file di prova; `-k soak --soak 10`, `--real FILM…`).
- `icon/` — icona (generata con Codex: `Dolly-1024.png`, `Dolly.icns`, script `genera_icone.py`).
- `legacy/` — prima versione (motore Python + interfaccia web), tenuta come riferimento.
- Aspetto senza aprire finestre: `Dolly --snapshot out.png --folder CARTELLA --play 1`.

## Telecomando dal telefono
Scheda **Altro → Telecomando dal telefono**: attivando l'interruttore l'app apre un piccolo server sulla rete locale (porta 8484, spento di default). Il telefono inquadra il QR o apre l'indirizzo, inserisce il PIN (4 cifre, in `~/Library/Application Support/Dolly/remote.json`) e comanda play/pausa, precedente/successivo, tempo, volume, muto, ripeti film, scena e intervalli. Non serve internet, solo una rete comune (router, hotspot…).
- Solo i comandi elencati in `allowed` (`Remote.swift`) sono accettati: niente cartelle, file, scalette o impostazioni dell'app.
- Cinque PIN sbagliati in un minuto bloccano i nuovi accessi; "Nuovo PIN" scollega i telefoni già abilitati.
- La pagina è `RemoteHTML.swift` (un file, nessuna richiesta esterna).
- Collaudo: `./test_dolly.py MEDIA -k remote` (avvia l'app con `--remote`).

