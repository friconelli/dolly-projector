#!/usr/bin/env python3
"""Collaudo di dolly.py: avvia veri server+mpv (senza video/audio reali) e li pilota via HTTP.

  ./test_dolly.py MEDIA_DIR                      # tutti i test sui file di prova (mp4/mkv)
  ./test_dolly.py MEDIA_DIR -k gaps,crash        # solo alcuni
  ./test_dolly.py MEDIA_DIR --real file1 file2   # in più prova su film veri (sola lettura)
  ./test_dolly.py MEDIA_DIR -k soak --soak 10    # soak di 10 minuti

MEDIA_DIR deve contenere: 01_a.mp4 02_b.mkv (2 audio, 2 sub, 2 capitoli) 03_hevc10.mkv 04_d.mp4 05_e.mkv 06_troncato.mp4 (file rotto).
"""
import argparse, json, os, random, shutil, signal, subprocess, sys, tempfile, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FAILS, PASSES, PORT = [], 0, [8800]

def check(cond, msg):
    global PASSES
    if cond: PASSES += 1; print("  ok  ", msg)
    else: FAILS.append(msg); print("  FAIL", msg)
    return cond

class Srv:
    def __init__(s, media, home=None, files=None, extra="--vo=null --ao=null", screen_args=("--screen", "0", "--windowed"), lang="it"):
        s.port = PORT[0]; PORT[0] += 1
        s.home = home or tempfile.mkdtemp(prefix="dolly-test-")
        s.folder = media; s.extra = extra; s.args = screen_args; s.p = None; s.lang = lang; s.start()
        if files is not None: s.set_items(files)
    def start(s):
        env = dict(os.environ, DOLLY_HOME=s.home, BROWSER="true", DOLLY_LANG=s.lang)   # i collaudi controllano i testi in italiano salvo diversa richiesta
        bin_ = os.environ.get("DOLLY_BIN")   # se impostato, collauda l'app Swift (--test-api) invece del motore Python
        cmd = [bin_, s.folder, "--test-api", str(s.port), "--mpv", s.extra, *s.args] if bin_ else [sys.executable, os.path.join(HERE, "legacy", "dolly.py"), s.folder, "--port", str(s.port), "--mpv", s.extra, *s.args]
        s.p = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=open(os.path.join(s.home, "server.log"), "a"))
        for _ in range(150):
            try:
                if s.state().get("ok") is not None: return
            except Exception: time.sleep(.2)
        raise RuntimeError("server non partito")
    def state(s):
        return json.load(urllib.request.urlopen(f"http://127.0.0.1:{s.port}/api/state", timeout=6))
    def act(s, **d):
        return json.load(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{s.port}/api/cmd", json.dumps(d).encode()), timeout=6))
    def set_items(s, files):
        s.act(a="clear")
        s.act(a="add", paths=[os.path.join(s.folder, f) if not os.path.isabs(f) else f for f in files])
    def mpv_pid(s):
        out = subprocess.run(["pgrep", "-f", f"dolly-{s.p.pid}-"], capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None
    def stop(s):
        if s.p and s.p.poll() is None:
            s.p.terminate()
            try: s.p.wait(5)
            except Exception: s.p.kill()
        subprocess.run(["pkill", "-f", f"dolly-{s.p.pid}-"], capture_output=True)
    def wait(s, cond, timeout=15, step=.1):
        t = time.time()
        while time.time() - t < timeout:
            try:
                st = s.state()
                if cond(st): return st
            except Exception: pass
            time.sleep(step)
        return None

def tail_seek(s, secs=2):
    """Porta il film in corso a `secs` secondi dalla fine (per non aspettare i film interi)."""
    st = s.wait(lambda x: x.get("playing") and x["dur"] > 0, 5)  # la durata è nota solo a file aperto
    if st and st["dur"] > secs + 1: s.act(a="seek", v=st["dur"] - secs, m="absolute")

def run_until_idle(s, fast=True, timeout=120):
    """Segue la sequenza fino a mode=idle. Ritorna (ordine idx, (t,mode,idx) timeline)."""
    t0, seen, tl, seeked = time.time(), [], [], set()
    while time.time() - t0 < timeout:
        st = s.state(); now = time.time() - t0
        tl.append((now, st["mode"], st["idx"], st.get("playing")))
        if st["mode"] == "playing" and st["idx"] not in seen: seen.append(st["idx"])
        if fast and st["mode"] == "playing" and st["idx"] not in seeked and st["time"] > 1 and st["dur"] > 4:
            seeked.add(st["idx"]); tail_seek(s)
        if st["mode"] == "idle" and seen: return seen, tl
        time.sleep(.1)
    return seen, tl

MEDIA = None
ALL = ["01_a.mp4", "02_b.mkv", "03_hevc10.mkv", "04_d.mp4", "05_e.mkv"]

def t_sequence():
    """Playlist mista mp4/mkv/hevc/ac3 che avanza da sola, film interi (tempo reale)."""
    s = Srv(MEDIA, files=ALL)
    try:
        s.act(a="play", i=0); t = time.time()
        seen, tl = run_until_idle(s, fast=False)
        el = time.time() - t
        check(seen == [0, 1, 2, 3, 4], f"tutti i 5 film in ordine ({seen})")
        check(abs(el - 42) < 6, f"durata totale ≈ somma dei film: {el:.1f}s (attesi ~42s)")
        check(s.state()["restarts"] == 0, "nessun riavvio di mpv")
        check(s.state()["mode"] == "idle" and not s.state()["playing"], "alla fine nero/idle")
    finally: s.stop()

def t_gaps():
    """Nero prima/dopo: durata dei neri misurata."""
    s = Srv(MEDIA, files=["01_a.mp4", "02_b.mkv", "04_d.mp4"])
    try:
        s.act(a="defaults", defpre=0.5, defpost=0)
        s.act(a="setitem", i=0, post=2); s.act(a="setitem", i=1, pre=1.5, post=3); s.act(a="setitem", i=2, pre=2)
        t = time.time(); s.act(a="play", i=0)
        st = s.wait(lambda x: x["mode"] == "playing", 5, .05); first = time.time() - t
        check(st and abs(first - 0.5) < 0.8, f"nero iniziale default 0.5s (misurato {first:.2f}s)")
        check(s.state()["mode"] in ("playing",) and s.state()["playing"], "dopo il nero parte il film")
        # fine film 0 -> gap 2 + 1.5 = 3.5s
        s.wait(lambda x: x["time"] > 1, 5); tail_seek(s, 1)
        g = s.wait(lambda x: x["mode"] == "gap", 6, .05); t1 = time.time()
        check(g is not None and not g["playing"], "durante il nero mpv è vuoto (schermo nero)")
        check(g and g["next"] == 1 and g["left"] > 2, f"countdown presente ({g and g['left']}s)")
        s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1, 8, .05); gap1 = time.time() - t1
        check(abs(gap1 - 3.5) < 1.0, f"nero tra film 0 e 1 = post(2)+pre(1.5)=3.5s (misurato {gap1:.2f}s)")
        # salta nero
        s.wait(lambda x: x["time"] > 1, 5); tail_seek(s, 1)
        g = s.wait(lambda x: x["mode"] == "gap", 6, .05)
        check(g is not None, "secondo nero (post 3 + pre 2 = 5s)")
        t2 = time.time(); s.act(a="skipgap")
        p = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 2, 3, .05)
        check(p is not None and time.time() - t2 < 1.5, "'Salta nero' parte subito")
        # fine ultimo film: dopo = default 0 -> idle
        s.wait(lambda x: x["time"] > 1, 5); tail_seek(s, 1)
        check(s.wait(lambda x: x["mode"] == "idle", 6) is not None, "dopo l'ultimo film resta nero/idle")
    finally: s.stop()

def t_tracks():
    """mkv con 2 audio, 2 sottotitoli, 2 capitoli + tutte le impostazioni del telecomando."""
    s = Srv(MEDIA, files=["02_b.mkv"])
    try:
        s.act(a="play", i=0); st = s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8)
        check(st is not None, "mkv parte")
        check(len(st["audio"]) == 2 and len(st["sub"]) == 2, f"2 audio e 2 sottotitoli visti: {[a['t'] for a in st['audio']]}")
        check(st["audio"][0]["sel"], "audio italiano scelto di default")
        check(st["sub"][0]["sel"] and not st["sub"][1]["sel"], "sottotitoli: parte la traccia segnata come predefinita nel file (ita)")
        check(len(st["chapters"]) == 2, f"capitoli: {[c['t'] for c in st['chapters']]}")
        s.act(a="aid", v=2); s.act(a="sid", v=1); time.sleep(.5); st = s.state()
        check(st["audio"][1]["sel"] and st["sub"][0]["sel"], "cambio traccia audio e sottotitolo")
        s.act(a="sid", v="no"); time.sleep(.4); check(not any(x["sel"] for x in s.state()["sub"]), "sottotitoli spenti")
        s.act(a="chapter", v=1); time.sleep(.6); st = s.state(); check(st["time"] >= 4.5, f"salto al capitolo 2 (t={st['time']:.1f})")
        s.act(a="seek", v=2, m="absolute"); time.sleep(.5); check(abs(s.state()["time"] - 2) < 1.2, "seek assoluto")
        s.act(a="seek", v=-1, m="relative"); time.sleep(.5); check(s.state()["time"] < 2, "seek relativo")
        for p, v in [("volume", 70), ("speed", 1.5), ("audio-delay", .3), ("sub-delay", -.5), ("sub-scale", 1.4), ("sub-pos", 90), ("video-zoom", .2),
                     ("panscan", .5), ("brightness", 10), ("contrast", -10), ("saturation", 15), ("gamma", 5), ("hue", 3), ("video-aspect-override", "2.35:1"),
                     ("loop-file", "no"), ("audio-channels", "stereo"), ("mute", True), ("deinterlace", True), ("sub-visibility", True)]:
            s.act(a="set", p=p, v=v)
        time.sleep(.5); pr = s.state()["props"]
        for p, v in [("volume", 70), ("speed", 1.5), ("audio-delay", .3), ("sub-delay", -.5), ("brightness", 10), ("panscan", .5), ("mute", True)]:
            check(pr[p] is not None and abs(float(pr[p]) - float(v)) < .01, f"proprietà {p}={pr[p]}")
        check(pr["video-aspect-override"] in (2.35, "2.35:1", 2.35), f"aspect override ({pr['video-aspect-override']})")
        s.act(a="resetvideo"); s.act(a="set", p="speed", v=1); s.act(a="set", p="mute", v=False); s.act(a="set", p="volume", v=100)
        s.act(a="set", p="volume", v=9999); time.sleep(.3); check(s.state()["props"]["volume"] <= 130, "valori fuori range vengono limitati")
        s.act(a="set", p="volume", v=100)
        r = s.act(a="set", p="non-esiste", v=1); time.sleep(.2); check("error" in r, "proprietà non ammessa rifiutata")
        s.act(a="toggle"); time.sleep(.4); check(s.state()["pause"], "pausa"); t = s.state()["time"]
        s.act(a="frame"); s.act(a="frame"); time.sleep(.3); check(s.state()["time"] > t, "avanzamento di un fotogramma")
        s.act(a="frameback"); s.act(a="toggle"); time.sleep(.4); check(not s.state()["pause"], "ripresa")
        s.act(a="seek", v=1, m="absolute"); s.act(a="abloop"); s.act(a="seek", v=3, m="absolute"); s.act(a="abloop"); time.sleep(.4)
        ab = s.state()["ab"]; check(ab[0] is not None and ab[1] is not None, f"loop A-B impostato {ab}"); s.act(a="abloop")
        s.act(a="text", v="Intervallo 10 minuti", ms=1500); time.sleep(.3); check(s.state()["ok"], "messaggio a schermo accettato")
        check(s.state()["restarts"] == 0, "nessun riavvio")
        for _ in range(3): s.act(a="set", p="speed", v=1)
        # le impostazioni restano al film successivo
    finally: s.stop()

def t_failures():
    """File mancante e file corrotto nella playlist: vengono saltati, la serata non si ferma."""
    home = tempfile.mkdtemp(prefix="dolly-test-")  # playlist scritta a mano: 'add' scarterebbe già il file inesistente
    json.dump({"items": [{"path": os.path.join(MEDIA, f), "pre": None, "post": None} for f in ["01_a.mp4", "inesistente.mkv", "06_troncato.mp4", "05_e.mkv"]]}, open(os.path.join(home, "current.json"), "w"))
    s = Srv(MEDIA, home=home)
    try:
        s.act(a="play", i=0); t = time.time()
        seen, tl = run_until_idle(s, timeout=60)
        check(0 in seen and 3 in seen, f"dopo i file rotti arriva comunque all'ultimo ({seen})")
        check(1 not in seen, "il file mancante viene saltato subito")
        check(time.time() - t < 25, f"il file corrotto non blocca la serata ({time.time() - t:.0f}s totali)")
        check(s.state()["mode"] == "idle", "finisce in idle")
        check(s.state()["restarts"] == 0, "nessun riavvio di mpv")
        its = s.state()["items"]; check(not its[1]["ok"], "file mancante segnalato rosso nella lista")
    finally: s.stop()

def t_stress():
    """300 comandi casuali in raffica + 4 thread che interrogano lo stato."""
    s = Srv(MEDIA, files=ALL + ["06_troncato.mp4"])
    stop = threading.Event(); errs = []
    def poller():
        while not stop.is_set():
            try: s.state()
            except Exception as e: errs.append(repr(e))
            time.sleep(.05)
    ths = [threading.Thread(target=poller) for _ in range(4)]
    try:
        [t.start() for t in ths]; rnd = random.Random(7)
        for n in range(300):
            c = rnd.choice(["play", "next", "prev", "toggle", "seek", "seek", "aid", "sid", "volume", "speed", "move", "setitem", "skipgap", "stop", "frame", "defaults"])
            try:
                if c == "play": s.act(a="play", i=rnd.randrange(6))
                elif c == "seek": s.act(a="seek", v=rnd.uniform(0, 9), m="absolute")
                elif c in ("aid", "sid"): s.act(a=c, v=rnd.choice([1, 2, "no"]))
                elif c == "volume": s.act(a="set", p="volume", v=rnd.uniform(0, 130))
                elif c == "speed": s.act(a="set", p="speed", v=rnd.choice([.5, 1, 2]))
                elif c == "move": s.act(a="move", i=rnd.randrange(6), d=rnd.choice([-1, 1]))
                elif c == "setitem": s.act(a="setitem", i=rnd.randrange(6), pre=rnd.choice([0, .2, ""]), post=rnd.choice([0, .2, ""]))
                elif c == "defaults": s.act(a="defaults", defpre=rnd.choice([0, .3]), defpost=rnd.choice([0, .3]), auto=True, loop=rnd.choice([True, False]))
                else: s.act(a=c)
            except Exception as e: errs.append(f"{c}: {e!r}")
            time.sleep(rnd.choice([0, 0, .02, .1]))
        stop.set(); [t.join() for t in ths]
        check(not errs, f"nessun errore HTTP durante la raffica ({len(errs)}: {errs[:2]})")
        s.act(a="defaults", defpre=0, defpost=0, auto=True, loop=False); s.act(a="set", p="speed", v=1); s.act(a="set", p="volume", v=100); s.act(a="stop")
        st = s.state(); check(st["ok"], "server e mpv rispondono ancora")
        s.act(a="play", i=0)
        check(s.wait(lambda x: x["mode"] == "playing" and x["playing"] and x["time"] > .5, 8) is not None, "dopo la raffica un film parte regolarmente")
        check(s.state()["restarts"] == 0, f"nessun riavvio di mpv (restarts={s.state()['restarts']})")
    finally: stop.set(); s.stop()

def t_crash():
    """mpv ucciso (crash) o congelato durante la proiezione: riparte dallo stesso punto."""
    s = Srv(MEDIA, files=["04_d.mp4", "05_e.mkv"])
    try:
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8)
        s.act(a="seek", v=4, m="absolute"); time.sleep(1.0)
        pid = s.mpv_pid(); check(pid is not None, f"trovato pid mpv {pid}")
        os.kill(pid, signal.SIGKILL); t = time.time()
        st = s.wait(lambda x: x["restarts"] == 1 and x["playing"] and x["time"] > 2.5, 15)
        check(st is not None, f"dopo kill -9 riparte da solo ({time.time() - t:.1f}s)")
        check(st and 3 < st["time"] < 8, f"riprende vicino al punto in cui era (t={st and st['time']:.1f}s, era ~5s)")
        check(st and st["idx"] == 0, "stesso film")
        # congelamento
        pid = s.mpv_pid(); os.kill(pid, signal.SIGSTOP); t = time.time()
        st = s.wait(lambda x: x["ok"] and x["restarts"] == 2 and x["playing"], 30, .5)
        check(st is not None, f"mpv congelato (SIGSTOP) viene riavviato in {time.time() - t:.1f}s")
        # crash mentre è in nero tra due film
        s.act(a="defaults", defpre=0, defpost=4); s.wait(lambda x: x["playing"], 5); tail_seek(s, 1)
        g = s.wait(lambda x: x["mode"] == "gap", 8)
        if g:
            os.kill(s.mpv_pid(), signal.SIGKILL)
            p = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1 and x["playing"], 15)
            check(p is not None, "crash durante il nero: il film successivo parte comunque")
    finally:
        subprocess.run(["pkill", "-CONT", "-f", f"dolly-{s.p.pid}-"], capture_output=True); s.stop()

def t_playlists():
    """Salva/carica/importa playlist, riordino, rimozione, persistenza al riavvio."""
    s = Srv(MEDIA, files=["01_a.mp4", "02_b.mkv", "03_hevc10.mkv"])
    try:
        s.act(a="move", i=0, d=1); s.act(a="remove", i=2); s.act(a="setitem", i=0, pre=3, post=1)
        s.act(a="defaults", defpre=1, defpost=2, auto=False, loop=True); s.act(a="pl_save", name="Serata 1")
        st = s.state(); check([i["name"] for i in st["items"]] == ["02_b.mkv", "01_a.mp4"], "riordino e rimozione")
        check("Serata 1" in st["saved"], "playlist salvata")
        s.stop(); s.start()  # riavvio con la stessa cartella dati
        st = s.state()
        check([i["name"] for i in st["items"]] == ["02_b.mkv", "01_a.mp4"] and st["items"][0]["pre"] == 3, "playlist corrente ripristinata dopo il riavvio")
        check(st["defpre"] == 1 and st["defpost"] == 2 and st["auto"] is False and st["loop"] is True, "impostazioni nero/avanzamento ripristinate")
        s.act(a="clear"); check(s.state()["items"] == [], "svuota")
        s.act(a="pl_load", name="Serata 1"); check(len(s.state()["items"]) == 2, "carica playlist salvata")
        m3u = os.path.join(s.home, "lista.m3u"); open(m3u, "w").write(f"#EXTM3U\n{MEDIA}/05_e.mkv\n# commento\n../x/inesistente.mkv\n{MEDIA}/04_d.mp4\n")
        s.act(a="pl_import", path=m3u); st = s.state()
        check([i["name"] for i in st["items"]] == ["05_e.mkv", "04_d.mp4"], f"import .m3u (ignora commenti e file inesistenti): {[i['name'] for i in st['items']]}")
        s.act(a="addlib"); check(len(s.state()["items"]) >= 2 + 5, "aggiungi tutta la cartella")
        s.act(a="pl_delete", name="Serata 1"); check("Serata 1" not in s.state()["saved"], "elimina playlist")
        s.act(a="remove", i=99); s.act(a="move", i=99, d=1); s.act(a="play", i=99); check(s.state()["ok"], "indici fuori range ignorati")
    finally: s.stop()

def t_modes():
    """Avanzamento automatico spento / ripeti playlist / riprendi dopo riavvio."""
    s = Srv(MEDIA, files=["01_a.mp4", "05_e.mkv"])
    try:
        s.act(a="defaults", auto=False); s.act(a="play", i=0); s.wait(lambda x: x["time"] > .5, 8); tail_seek(s, 1)
        st = s.wait(lambda x: x["mode"] == "idle", 8)
        check(st is not None and st["sel"] == 1 and not st["playing"], "auto spento: a fine film resta nero e prepara il successivo")
        s.act(a="toggle"); check(s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1, 5) is not None, "play avvia il film preparato")
        s.act(a="defaults", auto=True, loop=True); tail_seek(s, 1)
        check(s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 0, 8) is not None, "ripeti playlist: dopo l'ultimo torna al primo")
        s.act(a="defaults", loop=False); s.act(a="seek", v=3, m="absolute"); time.sleep(3)  # >2s: salva il punto (il film dura 8s)
        s.p.kill(); s.p.wait(); subprocess.run(["pkill", "-f", f"dolly-{s.p.pid}-"], capture_output=True)
        s.start(); st = s.state()
        check(st["resume"] is not None and st["resume"]["idx"] == 0 and st["resume"]["pos"] > 3, f"dopo un blocco dell'app propone di riprendere ({st['resume']})")
        s.act(a="resume"); st = s.wait(lambda x: x["mode"] == "playing" and x["playing"] and x["time"] > 2, 8)
        check(st is not None and st["time"] > 2, "riprendi riparte dal punto salvato")
    finally: s.stop()

def t_misc():
    """caffeinate attivo, port solo localhost, pagina servita."""
    s = Srv(MEDIA, files=["01_a.mp4"])
    try:
        out = subprocess.run(["pgrep", "-P", str(s.p.pid), "caffeinate"], capture_output=True, text=True).stdout.strip()
        check(out != "" or sys.platform != "darwin", "caffeinate attivo (il Mac non va in stop)")
        html = urllib.request.urlopen(f"http://127.0.0.1:{s.port}/", timeout=5).read().decode()
        check("<title>" in html, "pagina del telecomando servita")
        ls = subprocess.run(["lsof", "-nP", f"-iTCP:{s.port}", "-sTCP:LISTEN"], capture_output=True, text=True).stdout
        check("127.0.0.1" in ls and "*:" not in ls, "in ascolto solo su 127.0.0.1")
        s.stop(); time.sleep(1)
        check(subprocess.run(["pgrep", "-f", f"dolly-{s.p.pid}-"], capture_output=True).stdout.strip() == b"", "chiudendo lo script si chiude anche mpv")
        s = Srv(MEDIA, files=["01_a.mp4"]); s.act(a="play", i=0); time.sleep(1); s.act(a="quit"); time.sleep(2.5)
        check(s.p.poll() is not None, "il tasto Esci chiude lo script")
        check(subprocess.run(["pgrep", "-f", f"dolly-{s.p.pid}-"], capture_output=True).stdout.strip() == b"", "il tasto Esci non lascia mpv aperto (nemmeno riavviato)")
    finally: s.stop()

def t_cinema():
    """Elementi da sala: intervallo con conto alla rovescia, lingua audio/sub e livello per film; solo mp4/avi/mkv."""
    s = Srv(MEDIA, files=["02_b.mkv"])
    try:
        for f in ("x.mov", "x.webm", "x.m4v", "x.ts", "x.jpg", "x.txt"): open(os.path.join(s.home, f), "w").write("x")
        s.act(a="add", paths=[os.path.join(s.home, f) for f in ("x.mov", "x.webm", "x.m4v", "x.ts", "x.jpg", "x.txt")])
        check(len(s.state()["items"]) == 1, "mov/webm/m4v/ts/jpg/txt non vengono accettati")
        open(os.path.join(s.home, "y.AVI"), "w").write("x"); s.act(a="add", paths=[s.home])
        check([i["name"] for i in s.state()["items"]][1:] == ["y.AVI"], "cartelle: solo mp4/avi/mkv (anche maiuscole)")
        check("00_slide.jpg" not in s.state()["lib"] and len(s.state()["lib"]) == 7, f"la libreria mostra solo i video ({s.state()['lib']})")
        s.act(a="clear"); s.act(a="add", paths=[os.path.join(MEDIA, "02_b.mkv")]); s.act(a="addpause", secs=4, text="Intervallo")
        s.act(a="setitem", i=0, alang="eng", slang="ita", vol=55); s.act(a="move", i=1, d=-1)  # ordine: pausa, film
        check([i["kind"] for i in s.state()["items"]] == ["pausa", "film"], "ordine pausa/film")
        s.act(a="play", i=0); t = time.time()
        w = s.wait(lambda x: x["mode"] == "wait", 3, .05)
        check(w is not None and not w["playing"], "parte l'intervallo, schermo nero")
        check(w and 3 < w["left"] <= 4, f"conto alla rovescia dell'intervallo ({w and w['left']})")
        s.act(a="extend", v=3); time.sleep(.4); check(s.state()["left"] > 5.5, f"+3s all'intervallo ({s.state()['left']})")
        p = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1, 12, .05)
        check(p is not None and 5.5 < time.time() - t < 8.5, f"dopo l'intervallo parte il film ({time.time() - t:.1f}s)")
        time.sleep(.8); st = s.state()
        check([a["sel"] for a in st["audio"]] == [False, True], "lingua audio del film: eng")
        check(st["sub"][0]["sel"] and not st["sub"][1]["sel"], "sottotitoli del film: ita")
        check(abs(st["props"]["volume"] - 55) < 1, f"livello del film applicato ({st['props']['volume']})")
        s.act(a="setitem", i=1, alang="", slang="", vol=""); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "wait", 3); s.act(a="skipgap")
        p = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1, 3); time.sleep(.8); st = s.state()
        check(p is not None, "'Salta' durante la pausa passa al film")
        check(st["audio"][0]["sel"] and st["sub"][0]["sel"] and not st["sub"][1]["sel"], "senza preferenze: audio e sottotitoli predefiniti del file (le impostazioni del film precedente non restano)")
        r = s.act(a="addpause", secs=-5, text="x" * 500); check("error" not in r and s.state()["items"][-1]["secs"] >= 1, "valori assurdi vengono limitati")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_subtitles():
    """Stile sottotitoli: font, colore, bordo, dimensione, posizione; resta salvato come predefinito dopo il riavvio."""
    s = Srv(MEDIA, files=["02_b.mkv"])
    try:
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8)
        sty = {"sub-font": "Georgia", "sub-font-size": 60, "sub-color": "#FFD400", "sub-border-color": "#000000", "sub-border-size": 3.5,
               "sub-back-color": "#80000000", "sub-shadow-offset": 2, "sub-bold": True, "sub-italic": True, "sub-pos": 85, "sub-ass-override": "force"}
        s.act(a="setmany", props=sty); time.sleep(.5); pr = s.state()["props"]
        check(pr["sub-font"] == "Georgia" and pr["sub-font-size"] == 60 and pr["sub-bold"] and pr["sub-italic"], f"font/dimensione/grassetto/corsivo ({pr['sub-font']}, {pr['sub-font-size']})")
        check(str(pr["sub-color"]).upper().endswith("FFD400"), f"colore {pr['sub-color']}")
        check(pr["sub-border-size"] == 3.5 and pr["sub-shadow-offset"] == 2 and pr["sub-pos"] == 85 and pr["sub-ass-override"] == "force", "bordo, ombra, posizione, override ASS")
        r = s.act(a="set", p="sub-color", v="giallo"); check("error" in r, "colore non valido rifiutato")
        r = s.act(a="set", p="sub-ass-override", v="boh"); check("error" in r, "valore non valido rifiutato")
        s.act(a="set", p="sub-font-size", v=9999); time.sleep(.2); check(s.state()["props"]["sub-font-size"] <= 150, "dimensione limitata")
        s.act(a="set", p="sub-font-size", v=60)
        s.stop(); s.start(); s.act(a="play", i=0); st = s.wait(lambda x: x["mode"] == "playing" and x["time"] > .3, 8); time.sleep(.5); pr = s.state()["props"]
        check(pr["sub-font"] == "Georgia" and pr["sub-font-size"] == 60 and str(pr["sub-color"]).upper().endswith("FFD400"), "stile predefinito ricordato dopo il riavvio")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_autoresume():
    """Arresto imprevisto del motore durante un film: con --autoresume riparte da solo dal punto in cui era."""
    s = Srv(MEDIA, files=["04_d.mp4"])
    try:
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8); s.act(a="seek", v=4, m="absolute"); time.sleep(3.2)
        s.p.kill(); s.p.wait(); subprocess.run(["pkill", "-f", f"dolly-{s.p.pid}-"], capture_output=True)
        s.args = s.args + ("--autoresume",); s.start()
        st = s.wait(lambda x: x["mode"] == "playing" and x["playing"] and x["time"] > 3, 10)
        check(st is not None, "dopo l'arresto il film riparte da solo")
        check(st and 4 < st["time"] < 9, f"dal punto in cui era (t={st and st['time']:.1f}s)")
        s.stop(); s.args = s.args[:-1]; s.start()
        check(s.state()["mode"] == "idle", "senza --autoresume al riavvio non parte nulla da solo")
    finally: s.stop()

def t_prevloop():
    """Tasti precedente/successivo (da un media all'altro), ripeti questo film (poi la scaletta prosegue) ed elemento Nero."""
    s = Srv(MEDIA, files=["01_a.mp4", "04_d.mp4"])
    try:
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8)
        s.act(a="prev"); st = s.wait(lambda x: x["time"] < 2, 4)
        check(st is not None and st["idx"] == 0, "sul primo elemento non c'è un precedente: ⏮ riporta il film all'inizio")
        s.act(a="seek", v=5, m="absolute"); time.sleep(.6); s.act(a="next"); st = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1, 5)
        check(st is not None, "⏭ va al media successivo anche a film avanzato")
        s.act(a="seek", v=5, m="absolute"); time.sleep(.6); s.act(a="prev"); st = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 0, 5)
        check(st is not None, "⏮ va al media precedente anche dopo i primi secondi (non si limita a ripartire)")
        s.act(a="play", i=1); s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1 and x["time"] > .3, 6); time.sleep(.5)
        s.act(a="prev"); st = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 0, 5)
        check(st is not None, "dal secondo film, ⏮ va al precedente")
        # ripeti questo film
        s.act(a="set", p="loop-file", v="inf"); s.wait(lambda x: x["time"] > .5, 4); tail_seek(s, 1.5); time.sleep(4.5); st = s.state()
        check(st["mode"] == "playing" and st["idx"] == 0, f"con la ripetizione il film ricomincia e non passa al successivo (idx {st['idx']}, t={st['time']:.1f})")
        s.act(a="set", p="loop-file", v="no"); time.sleep(.5); tail_seek(s, 1)
        st = s.wait(lambda x: x["idx"] == 1 and x["mode"] in ("playing", "gap"), 8)
        check(st is not None, "tolta la ripetizione, a fine film la scaletta prosegue")
        s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1 and x["time"] > .3, 6); time.sleep(.5)
        check(s.state()["props"]["loop-file"] in ("no", False), f"il film successivo non è in ripetizione ({s.state()['props']['loop-file']})")
        s.act(a="set", p="loop-file", v="inf"); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 0 and x["time"] > .3, 6); time.sleep(.5)
        check(s.state()["props"]["loop-file"] in ("no", False), "cambiando film a mano la ripetizione si azzera")
        s.stop(); s.start(); time.sleep(.5)
        check(s.state()["props"]["loop-file"] in ("no", False, None), "la ripetizione non resta salvata tra una serata e l'altra")
        # elemento Nero
        s.act(a="clear"); s.act(a="add", paths=[os.path.join(MEDIA, "01_a.mp4"), os.path.join(MEDIA, "04_d.mp4")]); s.act(a="addblack", secs=2); s.act(a="move", i=2, d=-1)
        its = s.state()["items"]; check([i["kind"] for i in its] == ["film", "nero", "film"] and its[1]["name"] == "Nero (2 s)", f"elemento Nero tra due film ({its[1]['name']})")
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 6); tail_seek(s, 1)
        w = s.wait(lambda x: x["mode"] == "wait", 6, .05); t = time.time()
        check(w is not None and not w["playing"] and w["idx"] == 1, "a fine film parte il nero (schermo vuoto)")
        p = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 2, 6, .05)
        check(p is not None and abs(time.time() - t - 2) < 1, f"il nero dura 2 secondi ({time.time() - t:.1f}s)")
        s.act(a="setitem", i=1, secs=0.5); check(abs(s.state()["items"][1]["secs"] - 0.5) < .01, "durata del nero modificabile (anche 0,5 s)")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_lingue():
    """Lingua di audio/sottotitoli applicata anche a film già in corso, preferenza per la traccia completa su quella "forzata"; cambio cartella."""
    s = Srv(MEDIA, files=["02_b.mkv"])
    try:
        s.act(a="play", i=0); st = s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5 and x["audio"], 8); time.sleep(.5)
        st = s.state(); check(st["audio"][0]["sel"] and st["sub"][0]["sel"], "senza preferenze: audio ita e sottotitoli predefiniti del file (ita)")
        s.act(a="setitem", i=0, slang="eng"); st = s.wait(lambda x: x["sub"][1]["sel"], 3)
        check(st is not None and st["sub"][1]["sel"], "impostando i sottotitoli a film in corso, compaiono subito (eng)")
        s.act(a="setitem", i=0, alang="eng"); st = s.wait(lambda x: x["audio"][1]["sel"], 3)
        check(st is not None, "impostando l'audio a film in corso, cambia subito (eng)")
        s.act(a="clear"); s.act(a="add", paths=[os.path.join(MEDIA, "07_forzati.mkv")]); s.act(a="setitem", i=0, slang="ita"); s.act(a="play", i=0)
        s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8); time.sleep(1.0); st = s.state()
        sel = [t["t"] for t in st["sub"] if t["sel"]]; check(len(sel) == 1 and "Regolari" in sel[0], f"tra 'Forzati' e 'Regolari' sceglie quella completa ({sel})")
        # cambio cartella: la scaletta riparte dai film della nuova cartella
        other = tempfile.mkdtemp(prefix="cinema-altra-"); shutil.copy(os.path.join(MEDIA, "01_a.mp4"), other); shutil.copy(os.path.join(MEDIA, "05_e.mkv"), other)
        s.stop(); s.folder = other; s.args = s.args + ("--reset-playlist",); s.start()
        check(sorted(i["name"] for i in s.state()["items"]) == ["01_a.mp4", "05_e.mkv"], "con la nuova cartella la scaletta mostra i suoi film")
        check(s.state()["folder"] == other, "la libreria punta alla nuova cartella")
        shutil.rmtree(other, ignore_errors=True)
    finally: s.stop()

def t_reset_scelte():
    """La traccia audio e il 'nero immagine' scelti su un film non passano al successivo."""
    s = Srv(MEDIA, files=["02_b.mkv", "02_b.mkv"])
    try:
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5 and x["audio"], 8)
        s.act(a="aid", v=2); s.act(a="vid", v="no"); time.sleep(.5); st = s.state()
        check(st["audio"][1]["sel"] and not any(v["sel"] for v in st["video"]), "audio eng scelto e immagine tolta sul primo film")
        s.act(a="play", i=1); st = s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1 and x["time"] > .3 and x["audio"], 8); time.sleep(.6); st = s.state()
        check(st["audio"][0]["sel"], "il film successivo riparte con l'audio predefinito (ita)")
        check(any(v["sel"] for v in st["video"]), "e con l'immagine presente")
    finally: s.stop()

def t_sottotitoli():
    """Sottotitoli come nel file (traccia predefinita), nessuno, solo forzati, completi; per serata e per film."""
    s = Srv(MEDIA, files=["07_forzati.mkv"])
    try:
        def sel(): return [t["t"] for t in s.state()["sub"] if t["sel"]]
        s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5 and x["sub"], 8); time.sleep(.6)
        check(len(sel()) == 1 and "Forzati" in sel()[0], f"come nel file: parte la traccia segnata come predefinita nel file ({sel()})")
        s.act(a="defaults", defsub="none"); time.sleep(.8); check(sel() == [], "serata 'nessuno': i sottotitoli si spengono subito")
        s.act(a="defaults", defsub="full"); time.sleep(.8); check(len(sel()) == 1 and "Regolari" in sel()[0], f"serata 'completi': traccia completa nella lingua dell'audio ({sel()})")
        s.act(a="defaults", defsub="forced"); time.sleep(.8); check(len(sel()) == 1 and "Forzati" in sel()[0], f"serata 'solo forzati' ({sel()})")
        s.act(a="defaults", defsub="none"); s.act(a="setitem", i=0, submode="full"); time.sleep(.8)
        check(len(sel()) == 1 and "Regolari" in sel()[0], f"il film può avere un suo modo (completi) anche se la serata dice nessuno ({sel()})")
        s.act(a="setitem", i=0, submode=""); time.sleep(.8); check(sel() == [], "tolto il modo del film, torna quello della serata (nessuno)")
        s.act(a="defaults", defsub="file"); s.act(a="setitem", i=0, slang="eng"); time.sleep(.8)
        check(len(sel()) == 1 and "eng" in sel()[0], f"con una lingua scritta sul film si prende quella ({sel()})")
        s.act(a="setitem", i=0, slang=""); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5 and x["sub"], 8); time.sleep(.8)
        check(len(sel()) == 1 and "Forzati" in sel()[0], "riavviando il film senza preferenze ritorna la traccia del file")
        s.stop(); s.start(); check(s.state()["defsub"] == "file", "impostazione ricordata")
        s.act(a="defaults", defsub="forced"); s.act(a="pl_save", name="x"); s.act(a="defaults", defsub="none"); s.act(a="pl_load", name="x"); check(s.state()["defsub"] == "forced", "salvata con la scaletta")
        # ripristino allo stile iniziale
        s.act(a="setmany", props={"sub-font": "Georgia", "sub-font-size": 90, "sub-color": "#FF0000", "sub-bold": True, "sub-pos": 50, "sub-border-size": 8}); time.sleep(.4)
        s.act(a="resetsubstyle"); time.sleep(.4); pr = s.state()["props"]
        check(pr["sub-font"] == "sans-serif" and pr["sub-font-size"] == 38 and not pr["sub-bold"] and pr["sub-pos"] == 100 and abs(pr["sub-border-size"] - 1.65) < .01 and str(pr["sub-color"]).upper().endswith("FFFFFF"), f"'Ripristina' riporta lo stile allo stato iniziale ({pr['sub-font']}, {pr['sub-font-size']})")
        s.stop(); s.start(); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .3, 8); time.sleep(.5); pr = s.state()["props"]
        check(pr["sub-font"] == "sans-serif" and pr["sub-font-size"] == 38, "lo stile ripristinato resta tale dopo il riavvio")
        check(pr["sub-ass-override"] == "force", f"di default lo stile vale anche sui sottotitoli già stilizzati ({pr['sub-ass-override']})")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_loop_film():
    """Ripetizione di un singolo film nella scaletta (infinita o N volte), poi la scaletta prosegue; riordino col trascinamento."""
    s = Srv(MEDIA, files=["01_a.mp4", "04_d.mp4", "05_e.mkv"])
    try:
        s.act(a="setitem", i=0, loop=1); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8); tail_seek(s, 1.5); t = time.time()
        st = s.wait(lambda x: x["idx"] == 1 and x["mode"] == "playing", 20); el = time.time() - t
        check(st is not None and 8 < el < 13, f"loop 1: il film si ripete una volta e poi la scaletta prosegue ({el:.1f}s dalla fine del primo passaggio, attesi ~9,5)")
        s.act(a="setitem", i=0, loop=-1); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .5, 8); tail_seek(s, 1.5)
        time.sleep(11); st = s.state()
        check(st["idx"] == 0 and st["mode"] == "playing" and st["props"]["loop-file"] in ("inf", True), f"loop infinito: dopo la fine è ancora lo stesso film ({st['props']['loop-file']})")
        s.act(a="set", p="loop-file", v="no"); tail_seek(s, 1)
        check(s.wait(lambda x: x["idx"] == 1, 8) is not None, "disattivando il loop la scaletta prosegue")
        s.act(a="setitem", i=0, loop=0); s.act(a="play", i=0); s.wait(lambda x: x["mode"] == "playing" and x["time"] > .3, 6); time.sleep(.4)
        check(s.state()["props"]["loop-file"] in ("no", False), "senza loop impostato il film non si ripete")
        # riordino
        s.act(a="reorder", **{"from": 0, "to": 2}); its = [i["name"] for i in s.state()["items"]]; st = s.state()
        check(its == ["04_d.mp4", "05_e.mkv", "01_a.mp4"] and st["idx"] == 2, f"trascinando il primo in fondo l'ordine cambia e il film in corso resta lo stesso ({its}, idx {st['idx']})")
        s.act(a="reorder", **{"from": 2, "to": 0}); check([i["name"] for i in s.state()["items"]][0] == "01_a.mp4", "riordino inverso")
        s.act(a="reorder", **{"from": 9, "to": 0}); s.act(a="reorder", **{"from": 1, "to": 1}); check(s.state()["ok"], "indici fuori range ignorati")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_remote():
    """Telecomando dal telefono: PIN, accesso, comandi ammessi e rifiutati, stato ridotto, anteprima."""
    import urllib.error
    os.environ["DOLLY_REMOTE_PORT"] = "8590"   # non la 8484: potrebbe esserci già un'app vera aperta
    s = Srv(MEDIA, files=["01_a.mp4", "04_d.mp4"], screen_args=("--screen", "0", "--windowed", "--remote"))
    base = "http://127.0.0.1:8590"
    def call(path, body=None, tok=None):
        rq = urllib.request.Request(base + path, json.dumps(body).encode() if body is not None else None, {"X-Token": tok} if tok else {})
        try:
            r = urllib.request.urlopen(rq, timeout=6); return r.status, r.read()
        except urllib.error.HTTPError as e: return e.code, e.read()
    try:
        time.sleep(.5)
        cfg = json.load(open(os.path.join(s.home, "remote.json"))); pin = cfg["pin"]
        check(len(pin) == 4 and pin.isdigit(), f"il PIN è di 4 cifre ({pin})")
        c, b = call("/"); check(c == 200 and b"Dolly Projector" in b, "la pagina del telecomando viene servita")
        check(b"://" not in b, "la pagina non contiene richieste esterne (funziona senza internet)")
        check(call("/api/state")[0] == 401, "senza accesso lo stato è rifiutato")
        check(call("/api/cmd", {"a": "toggle"})[0] == 401, "senza accesso i comandi sono rifiutati")
        c, b = call("/api/login", {"pin": "x" + pin}); check(c == 401, "PIN errato rifiutato")
        c, b = call("/api/login", {"pin": pin}); tok = json.loads(b).get("token") if c == 200 else None
        check(bool(tok), "PIN giusto: arriva il token")
        c, b = call("/api/state", tok=tok); st = json.loads(b)
        check(c == 200 and set(st) >= {"mode", "items", "props", "time", "dur"} and "folder" not in st and "lib" not in st, "stato ridotto: niente cartelle né elenco della libreria")
        c, b = call("/api/cmd", {"a": "play", "i": 0}, tok); check(c == 200, "play dal telefono")
        st2 = s.wait(lambda x: x["mode"] == "playing" and x["time"] > .3, 8); check(st2 is not None, "il film parte davvero")
        call("/api/cmd", {"a": "toggle"}, tok); st3 = s.wait(lambda x: x.get("pause"), 4); check(st3 is not None, "pausa dal telefono")
        call("/api/cmd", {"a": "toggle"}, tok); check(s.wait(lambda x: not x.get("pause"), 4) is not None, "riprende dal telefono")
        call("/api/cmd", {"a": "set", "p": "volume", "v": 40}, tok); check(s.wait(lambda x: abs((x["props"].get("volume") or 0) - 40) < 1, 4) is not None, "volume dal telefono")
        c, _ = call("/api/cmd", {"a": "setitem", "i": 0, "loop": -1}, tok); check(c == 200 and s.state()["items"][0]["loop"] == -1, "ripeti film dal telefono")
        c, b = call("/api/cmd", {"a": "clear"}, tok); check(c == 400 and len(s.state()["items"]) == 2, "il comando 'svuota la scena' è rifiutato")
        c, b = call("/api/cmd", {"a": "add", "paths": ["/etc"]}, tok); check(c == 400, "aggiungere file è rifiutato")
        c, b = call("/api/cmd", {"a": "set", "p": "sub-font", "v": "x"}, tok); check(c == 400, "impostazioni diverse da volume/muto rifiutate")
        c, b = call("/api/cmd", {"a": "setitem", "i": 0, "pre": 99}, tok); check(c == 400, "setitem con campi diversi da 'loop' rifiutato")
        c, b = call("/api/preview", tok=tok); check(c in (200, 204), f"anteprima raggiungibile (codice {c})")
        c, _ = call("/api/state", tok="0" * 32); check(c == 401, "un token inventato non funziona")
        for _ in range(6): call("/api/login", {"pin": "0000x"})
        c, _ = call("/api/login", {"pin": pin}); check(c == 429, "dopo troppi tentativi sbagliati il PIN giusto viene bloccato per un po'")
        c, _ = call("/api/state", tok=tok); check(c == 200, "ma chi è già collegato continua a funzionare")
        s.stop(); s.start(); time.sleep(.8)
        pin2 = json.load(open(os.path.join(s.home, "remote.json")))["pin"]
        check(pin2 != pin, f"a ogni avvio il PIN è nuovo ({pin} -> {pin2})")
        c, _ = call("/api/state", tok=tok); check(c == 401, "dopo il riavvio i telefoni già collegati devono rifare l'accesso")
        c, b = call("/api/login", {"pin": pin2}); check(c == 200 and json.loads(b).get("token"), "con il PIN nuovo l'accesso funziona")
    finally: s.stop()

def t_update():
    """Aggiornamento dal menu: confronto versioni, scarico, SHA-256, identità dell'app e rifiuto di file alterati."""
    import hashlib, http.server, functools
    d = tempfile.mkdtemp(prefix="dolly-upd-")
    def make(version, bid="app.dollyprojector.Dolly"):
        app = os.path.join(d, version + bid[-3:], "Dolly Projector.app", "Contents"); os.makedirs(app)
        open(os.path.join(app, "Info.plist"), "w").write(f'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>{bid}</string><key>CFBundleShortVersionString</key><string>{version}</string></dict></plist>')
        z = os.path.join(d, f"Dolly-{version}-{bid[-3:]}.zip"); subprocess.run(["ditto", "-c", "-k", "--keepParent", os.path.join(d, version + bid[-3:], "Dolly Projector.app"), z], check=True)
        return z, hashlib.sha256(open(z, "rb").read()).hexdigest()
    port = 8899
    h = http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(http.server.SimpleHTTPRequestHandler, directory=d))
    h.RequestHandlerClass.log_message = lambda *a: None
    threading.Thread(target=h.serve_forever, daemon=True).start()
    bin_ = os.environ["DOLLY_BIN"]
    def run(info, current="0.2.1", dl=True):
        json.dump(info, open(os.path.join(d, "version.json"), "w"))
        r = subprocess.run([bin_, "--selftest-update"] + (["--download"] if dl else []), capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, DOLLY_UPDATE_URL=f"http://127.0.0.1:{port}/version.json", DOLLY_VERSION=current))
        try: return json.loads(r.stdout.strip().splitlines()[-1])
        except Exception: return {"error": r.stdout + r.stderr}
    try:
        z, sha = make("9.9.9"); url = f"http://127.0.0.1:{port}/{os.path.basename(z)}"
        o = run({"version": "9.9.9", "url": url, "sha256": sha, "bytes": 1})
        check(o.get("newer") is True and o.get("version") == "9.9.9", f"riconosce la versione più recente ({o})")
        check(os.path.isdir(o.get("app", "") or "/nonexistent"), "scarica, verifica ed estrae la nuova app")
        o = run({"version": "0.2.1", "url": url, "sha256": sha}, dl=False); check(o.get("newer") is False, "stessa versione: nessun aggiornamento")
        o = run({"version": "0.10.0", "url": url, "sha256": sha}, current="0.9.5", dl=False); check(o.get("newer") is True, "0.10.0 è più recente di 0.9.5 (confronto numerico)")
        o = run({"version": "9.9.9", "url": url, "sha256": "0" * 64}); check("SHA-256" in o.get("error", ""), "file con SHA-256 diverso: rifiutato")
        o = run({"version": "9.9.8", "url": url, "sha256": sha}); check("non contiene" in o.get("error", ""), "versione dell'archivio diversa da quella annunciata: rifiutato")
        z2, sha2 = make("9.9.9", bid="evil.app.xyz"); o = run({"version": "9.9.9", "url": f"http://127.0.0.1:{port}/{os.path.basename(z2)}", "sha256": sha2}); check("non contiene" in o.get("error", ""), "app con un altro identificativo: rifiutata")
        o = run({"version": "9.9.9", "url": "http://example.com/x.zip", "sha256": sha}, dl=False); check("non valida" in o.get("error", ""), "un indirizzo http non locale è rifiutato")
    finally: h.shutdown()

def t_trascina_file():
    """Trascinamento di file dal Finder: inserimento tra due righe, in fondo, cartelle, formati non ammessi; il film in corso non cambia."""
    s = Srv(MEDIA, files=["01_a.mp4", "04_d.mp4"])
    try:
        s.act(a="play", i=1); s.wait(lambda x: x["mode"] == "playing" and x["idx"] == 1 and x["time"] > .3, 8)
        s.act(a="add", paths=[os.path.join(MEDIA, "05_e.mkv")], at=0); st = s.state()
        check([i["name"] for i in st["items"]] == ["05_e.mkv", "01_a.mp4", "04_d.mp4"], f"inserito all'inizio ({[i['name'] for i in st['items']]})")
        check(st["idx"] == 2 and st["mode"] == "playing", f"il film in corso resta lo stesso: idx scala a {st['idx']}")
        s.act(a="add", paths=[os.path.join(MEDIA, "02_b.mkv")], at=2); st = s.state()
        check([i["name"] for i in st["items"]] == ["05_e.mkv", "01_a.mp4", "02_b.mkv", "04_d.mp4"] and st["idx"] == 3, "inserito in mezzo: chi segue scala")
        s.act(a="add", paths=[os.path.join(MEDIA, "03_hevc10.mkv")]); check(s.state()["items"][-1]["name"] == "03_hevc10.mkv", "senza posizione va in fondo")
        n = len(s.state()["items"]); s.act(a="add", paths=[os.path.join(MEDIA, "eng.srt"), os.path.join(MEDIA, "ch.txt")], at=1)
        check(len(s.state()["items"]) == n, "file che non sono mp4/avi/mkv vengono ignorati")
        s.act(a="add", paths=[os.path.join(MEDIA, "01_a.mp4")], at=99); check(s.state()["items"][-1]["name"] == "01_a.mp4", "posizione fuori range: in fondo")
        s.act(a="clear"); s.act(a="add", paths=[MEDIA], at=0); names = [i["name"] for i in s.state()["items"]]
        check(len(names) >= 6 and all(x.rsplit(".", 1)[-1] in ("mp4", "mkv", "avi") for x in names), f"una cartella aggiunge i suoi film ({len(names)})")
        check(s.state()["restarts"] == 0, "nessun riavvio")
    finally: s.stop()

def t_inglese():
    """Interfaccia in inglese: stessi dati, testi tradotti (nomi, etichette, errori, pagina del telecomando); l'italiano resta com'era."""
    os.environ["DOLLY_REMOTE_PORT"] = "8592"
    for lang, nero, interv, err, remote in (("en", "Black (2 s)", "Intermission", "index out of range", "en"), ("it", "Nero (2 s)", "Intervallo", "indice fuori range", "it")):
        s = Srv(MEDIA, files=["01_a.mp4", "04_d.mp4"], screen_args=("--screen", "0", "--windowed", "--remote"), lang=lang)
        try:
            s.act(a="addblack", secs=2); s.act(a="addpause", secs=60)
            its = s.state()["items"]
            check(its[2]["name"] == nero, f"[{lang}] nome dell'elemento nero: {its[2]['name']}")
            check(its[3]["text"] == interv, f"[{lang}] testo predefinito dell'intervallo: {its[3]['text']}")
            check(s.act(a="setitem", i=99).get("error") == err, f"[{lang}] errore comprensibile: {s.act(a='setitem', i=99).get('error')}")
            s.act(a="setitem", i=0, pre=1.5); s.act(a="play", i=0); st = s.wait(lambda x: x["mode"] == "gap", 4)
            check(st is not None and st["label"] == ("Black before the film" if lang == "en" else "Nero prima del film"), f"[{lang}] etichetta del nero prima del film: {st and st['label']}")
            time.sleep(.5); html = urllib.request.urlopen("http://127.0.0.1:8592/", timeout=5).read().decode()
            check(f'<html lang="{remote}">' in html, f"[{lang}] la pagina del telecomando è in {remote}")
        finally: s.stop()

def t_trascinamento_logica():
    """Logica del riordino con il trascinamento: da dove si rilascia a quale riga/posizione corrisponde (righe da 48 pt a passo 50)."""
    r = subprocess.run([os.environ["DOLLY_BIN"], "--selftest-drag"], capture_output=True, text=True, timeout=30)
    o = json.loads(r.stdout.strip().splitlines()[-1]); ys = [-30, 10, 26, 74, 120, 175, 240, 400]
    check(o["row"] == [0, 0, 0, 1, 2, 3, 4, 4], f"riga più vicina al puntatore ({o['row']})")
    check(o["ins"] == [0, 0, 1, 2, 2, 4, 5, 5], f"posizione di inserimento dei file ({o['ins']})")
    check(o["rowEmpty"] == 0 and o["insEmpty"] == 0, "scaletta vuota: indice 0")

def t_trascinamento_gui():
    """Riordino della scaletta con il trascinamento della maniglia (eventi mouse veri nella finestra, senza passare dal motore)."""
    M = MEDIA
    def drag(spec):
        home = tempfile.mkdtemp(prefix="dolly-dnd-")
        r = subprocess.run([os.environ["DOLLY_BIN"], "--snapshot", os.path.join(home, "s.png"), "--folder", M, "--wait", "5", "--size", "1240x720"],
                           capture_output=True, text=True, timeout=90, env=dict(os.environ, DOLLY_HOME=home, DOLLY_LANG="it", DOLLY_DRAG=spec))
        for l in r.stdout.splitlines():
            if l.startswith("ORDER:"): return [x.rsplit(".", 1)[0] for x in l[6:].strip().split("|")]
        return None
    base = ["01_a", "02_b", "03_hevc10", "04_d", "05_e", "06_troncato", "07_forzati"]
    o = drag("20.5,109,229"); check(o == ["02_b", "03_hevc10", "04_d", "01_a", "05_e", "06_troncato", "07_forzati"], f"trascinando la prima riga di 3 posti in giù ({o})")
    o = drag("20.5,229,109"); check(o == ["04_d", "01_a", "02_b", "03_hevc10", "05_e", "06_troncato", "07_forzati"], f"trascinando la quarta riga in cima ({o})")
    o = drag("20.5,109,500"); check(o == base[1:] + ["01_a"], f"trascinando oltre l'ultima riga va in coda ({o})")
    o = drag("20.5,109,112"); check(o == base, f"un trascinamento minimo non cambia nulla ({o})")

def t_orphan():
    """Se lo script viene ucciso di forza, al riavvio il vecchio mpv rimasto sullo schermo viene chiuso."""
    s = Srv(MEDIA, files=["01_a.mp4"])
    try:
        old = s.mpv_pid(); s.p.kill(); s.p.wait(); time.sleep(.5)
        check(subprocess.run(["ps", "-p", str(old)], capture_output=True).returncode == 0, "mpv rimasto orfano dopo kill -9 dello script")
        s.start(); time.sleep(.5)
        check(subprocess.run(["ps", "-p", str(old)], capture_output=True).returncode != 0, "al riavvio l'mpv orfano viene chiuso")
        check(s.mpv_pid() is not None and s.mpv_pid() != old, "ne parte uno nuovo")
    finally: s.stop()

def t_real(files):
    """Film veri (sola lettura): avvio, seek, cambio traccia, nessun riavvio."""
    for f in files:
        print("  >", os.path.basename(f))
        s = Srv(os.path.dirname(f), files=[f])
        try:
            s.act(a="set", p="volume", v=0); s.act(a="play", i=0)
            st = s.wait(lambda x: x["mode"] == "playing" and x["playing"] and x["time"] > .5, 40)
            check(st is not None, "parte");
            if not st: continue
            print("     ", st["info"], f"audio={[a['t'] for a in st['audio']]} sub={len(st['sub'])}")
            for frac in (.25, .5, .9, .1):
                s.act(a="seek", v=st["dur"] * frac, m="absolute"); time.sleep(2.5); x = s.state()
                check(x["ok"] and x["playing"] and abs(x["time"] - st["dur"] * frac) < 6, f"seek al {int(frac * 100)}% (t={x['time']:.0f}/{st['dur']:.0f})")
            for a in st["audio"][1:]:
                s.act(a="aid", v=a["id"]); time.sleep(1.2); check(any(t["sel"] and t["id"] == a["id"] for t in s.state()["audio"]), f"audio {a['t']}")
            for a in st["sub"][:2]:
                s.act(a="sid", v=a["id"]); time.sleep(1.2); check(any(t["sel"] and t["id"] == a["id"] for t in s.state()["sub"]), f"sottotitolo {a['t']}")
            s.act(a="sid", v="no"); time.sleep(10)
            x = s.state(); check(x["restarts"] == 0 and x["playing"], f"dopo 10s ancora in riproduzione, nessun riavvio (frame persi: {x['info']['dropped']})")
        finally: s.stop()

def t_soak(minutes):
    """Playlist in loop con seek casuali per N minuti: mpv/python non devono crescere né riavviarsi."""
    s = Srv(MEDIA, files=ALL)
    def rss(pid): return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0) // 1024
    try:
        s.act(a="defaults", defpre=.3, defpost=.3, auto=True, loop=True); s.act(a="play", i=0)
        rnd = random.Random(3); t0 = time.time(); films = set(); samples = []; errs = 0
        while time.time() - t0 < minutes * 60:
            try:
                st = s.state()
                if st["mode"] == "playing": films.add(st["idx"])
                if st["mode"] == "playing" and rnd.random() < .5: s.act(a="seek", v=rnd.uniform(0, max(1, st["dur"] - 2)), m="absolute")
                if rnd.random() < .1: s.act(a="next")
            except Exception: errs += 1
            if int(time.time() - t0) % 30 == 0: samples.append((rss(s.p.pid), rss(s.mpv_pid() or 0)))
            time.sleep(1)
        st = s.state(); check(st["ok"] and st["restarts"] == 0, f"{minutes} min senza riavvii, ancora vivo (restarts={st['restarts']}, errori={errs})")
        check(len(films) == 5, f"ha toccato tutti i film ({sorted(films)})")
        if len(samples) > 3: check(samples[-1][0] < samples[1][0] * 1.6 + 30 and samples[-1][1] < samples[1][1] * 1.6 + 100, f"memoria stabile python/mpv MB: {samples[1]} → {samples[-1]}")
    finally: s.stop()

TESTS = {"sequence": t_sequence, "gaps": t_gaps, "tracks": t_tracks, "failures": t_failures, "stress": t_stress, "crash": t_crash, "remote": t_remote, "trascinamento_gui": t_trascinamento_gui, "trascinamento_logica": t_trascinamento_logica, "inglese": t_inglese, "trascina_file": t_trascina_file, "update": t_update,
         "playlists": t_playlists, "modes": t_modes, "misc": t_misc, "orphan": t_orphan, "cinema": t_cinema, "subtitles": t_subtitles, "autoresume": t_autoresume, "prevloop": t_prevloop, "lingue": t_lingue, "reset": t_reset_scelte, "sottotitoli": t_sottotitoli, "loopfilm": t_loop_film}

def main():
    global MEDIA
    ap = argparse.ArgumentParser(); ap.add_argument("media"); ap.add_argument("-k", default=""); ap.add_argument("--real", nargs="*", default=[])
    ap.add_argument("--soak", type=float, default=0); a = ap.parse_args(); MEDIA = os.path.abspath(a.media)
    os.environ["DOLLY_LANG"] = "it"   # i collaudi controllano i testi in italiano: senza questo l'app leggerebbe la lingua scelta nelle preferenze reali dell'utente
    names = [k for k in a.k.split(",") if k] or list(TESTS)
    for n in names:
        if n == "soak": continue
        print(f"\n== {n}: {TESTS[n].__doc__.strip().splitlines()[0]}"); t = time.time()
        try: TESTS[n]()
        except Exception as e: FAILS.append(f"{n}: eccezione {e!r}"); print("  FAIL eccezione", repr(e))
        print(f"  ({time.time() - t:.0f}s)")
    if a.real: print("\n== real"); t_real([os.path.abspath(f) for f in a.real])
    if a.soak or "soak" in names: print("\n== soak"); t_soak(a.soak or 5)
    print(f"\n{PASSES} controlli ok, {len(FAILS)} falliti")
    for f in FAILS: print("  -", f)
    sys.exit(1 if FAILS else 0)

if __name__ == "__main__": main()
