#!/usr/bin/env python3
"""Dolly: regia di proiezione per il cinema. mpv a schermo intero, senza controlli, sullo schermo della sala;
telecomando (pagina web servita solo su 127.0.0.1, mostrata nell'app Dolly) sullo schermo di servizio.

  ./dolly.py "~/Desktop/Opere Prime/Film" --screen 1
  ./dolly.py --screen 0 --windowed        # prove su un solo schermo

La sequenza dei film (playlist, nero prima/dopo, avanzamento) la gestisce questo script, non mpv:
mpv resta sempre aperto (nero quando non c'è un film) e se si pianta viene riavviato riprendendo dal punto in cui era.
Solo libreria standard Python; mpv è pilotato via socket IPC.
"""
import argparse, atexit, json, os, re, shlex, signal, socket, subprocess, sys, tempfile, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.environ.get("DOLLY_HOME") or os.path.expanduser("~/Library/Application Support/Dolly")
MPV = os.environ.get("DOLLY_MPV", "/Applications/mpv.app/Contents/MacOS/mpv")
EXT = {".mp4", ".avi", ".mkv"}  # gli unici formati supportati
log = lambda *a: print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)

# proprietà impostabili dal telecomando: nome -> (tipo, min, max). Tutto il resto viene rifiutato.
PROPS = {"sub-font": ("s",), "sub-font-size": ("f", 10, 150), "sub-color": ("s",), "sub-border-color": ("s",), "sub-border-size": ("f", 0, 15),
         "sub-back-color": ("s",), "sub-shadow-offset": ("f", 0, 15), "sub-bold": ("b",), "sub-italic": ("b",), "sub-ass-override": ("s",),
         "audio-device": ("s",), "volume": ("f", 0, 130), "mute": ("b",), "speed": ("f", .25, 4), "audio-delay": ("f", -10, 10), "sub-delay": ("f", -30, 30),
         "sub-scale": ("f", .3, 3), "sub-pos": ("f", 0, 100), "sub-visibility": ("b",), "video-zoom": ("f", -1, 2), "video-pan-x": ("f", -1, 1),
         "video-pan-y": ("f", -1, 1), "panscan": ("f", 0, 1), "brightness": ("f", -100, 100), "contrast": ("f", -100, 100),
         "saturation": ("f", -100, 100), "gamma": ("f", -100, 100), "hue": ("f", -100, 100), "video-aspect-override": ("s",),
         "deinterlace": ("b",), "loop-file": ("s",), "audio-channels": ("s",), "ontop": ("b",)}
READ = list(PROPS)

class Mpv:
    def __init__(s, extra, windowed, screen):
        s.extra, s.windowed, s.screen = extra, windowed, screen
        s.lock, s.rid, s.proc, s.sock = threading.Lock(), 0, None, None
    def start(s):
        s.sock = os.path.join(tempfile.gettempdir(), f"dolly-{os.getpid()}-{int(time.time())}.sock")
        a = [MPV, "--idle=yes", "--force-window=yes", "--keep-open=no", "--no-osc", "--no-input-default-bindings", "--no-input-cursor",
             "--osd-level=0", "--osd-font-size=64", "--osd-align-x=center", "--osd-align-y=center", "--osd-bold=yes", "--screenshot-format=jpeg", "--screenshot-jpeg-quality=60", "--cursor-autohide=always", "--audio-display=no", "--no-terminal", "--hwdec=auto-safe",
             "--alang=ita,it,eng,en", "--sid=no", "--no-resume-playback", "--demuxer-readahead-secs=30", f"--screen={s.screen}",
             f"--input-ipc-server={s.sock}"]
        a += ["--no-border"] if s.windowed else ["--fs", f"--fs-screen={s.screen}"]
        s.proc = subprocess.Popen(a + s.extra)
        for _ in range(300):
            if os.path.exists(s.sock) and s.proc.poll() is None: return
            time.sleep(.1)
        raise RuntimeError("mpv non è partito")
    def alive(s): return s.proc is not None and s.proc.poll() is None
    def kill(s):
        if s.proc and s.proc.poll() is None: s.proc.kill(); s.proc.wait()
    def ipc(s, cmds, timeout=2):
        """Più comandi su un'unica connessione. Eccezione se mpv non risponde; None per le proprietà non disponibili."""
        with s.lock:
            c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(s.sock)
            try:
                ids, out = {}, [None] * len(cmds)
                for i, cmd in enumerate(cmds):
                    s.rid += 1; ids[s.rid] = i
                    c.sendall((json.dumps({"command": cmd, "request_id": s.rid}) + "\n").encode())
                buf, left = b"", len(cmds)
                while left:
                    chunk = c.recv(65536)
                    if not chunk: raise ConnectionError("mpv ha chiuso la connessione")
                    buf += chunk; *lines, buf = buf.split(b"\n")
                    for l in lines:
                        r = json.loads(l); i = ids.get(r.get("request_id"))
                        if i is not None: out[i] = r.get("data") if r.get("error") == "success" else None; left -= 1
                return out
            finally: c.close()
    def get(s, *props): return dict(zip(props, s.ipc([["get_property", p] for p in props])))

def videos_in(path):
    if os.path.isdir(path): return [os.path.join(path, f) for f in sorted(os.listdir(path)) if os.path.splitext(f)[1].lower() in EXT and not f.startswith(".")]
    return [path] if os.path.isfile(path) and os.path.splitext(path)[1].lower() in EXT else []

def mk(path="", kind=None, **kw):
    """Elemento di scaletta: film (mp4/avi/mkv) | pausa (intervallo con testo, schermo nero)."""
    kind = kind or "film"
    it = {"kind": kind, "path": path, "pre": None, "post": None, "vol": None, "alang": "", "slang": "", "secs": 600.0, "text": ""}
    it.update(kw); return it

def pick(kind):
    """Finestra nativa di macOS per scegliere file/cartelle (si apre sul Mac, non nella pagina web)."""
    one = {"files": 'choose file of type {"mp4", "avi", "mkv"} with prompt "Aggiungi film (mp4, avi, mkv)" with multiple selections allowed',
           "folder": 'choose folder with prompt "Aggiungi tutti i film di una cartella"',
           "playlist": 'choose file of type {"m3u", "m3u8"} with prompt "Scegli una playlist (.m3u)"'}[kind]
    script = f'set r to ({one})\nif class of r is not list then set r to {{r}}\nset o to {{}}\nrepeat with f in r\nset end of o to POSIX path of f\nend repeat\nset AppleScript\'s text item delimiters to linefeed\nreturn o as text'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return [l for l in r.stdout.split("\n") if l]

class Player:
    def __init__(s, a):
        s.a, s.lock = a, threading.RLock()
        s.folder = os.path.expanduser(a.folder)
        os.makedirs(os.path.join(HOME, "playlists"), exist_ok=True)
        s.mpv = Mpv(shlex.split(a.mpv), a.windowed, a.screen)
        s.items, s.name, s.defpre, s.defpost, s.auto, s.loop, s.prefs, s.resume = [], "Playlist", 0.0, 0.0, True, False, {}, None
        s.mode, s.idx, s.sel, s.next, s.until, s.label = "idle", -1, 0, -1, 0, ""
        s.pos = s.dur = s.loaded_at = s.shown = s.pv_t = 0; s.pv = None; s.retries = s.fails = 0; s.err = None; s.restarts = 0; s.last_save = 0; s.quitting = False
        s.caff = subprocess.Popen(["caffeinate", "-dis"]) if sys.platform == "darwin" else None  # il Mac non deve dormire durante la serata
        s.load_current(); s.kill_orphans()
        s.mpv.start(); s.apply_prefs()
        if a.autoresume and s.resume and s.resume["idx"] < len(s.items) and time.time() - s.resume.get("t", 0) < 60:  # riavvio dopo un arresto imprevisto, a proiezione in corso
            log("riprendo da solo:", s.resume); s.load(s.resume["idx"], start=s.resume["pos"])
        threading.Thread(target=s.run, daemon=True).start()

    # ---------- persistenza ----------
    def cfile(s): return os.path.join(HOME, "current.json")
    def dump(s): return {"name": s.name, "items": s.items, "defpre": s.defpre, "defpost": s.defpost, "auto": s.auto, "loop": s.loop, "prefs": s.prefs, "resume": s.resume}
    def save(s):
        tmp = s.cfile() + ".tmp"; json.dump(s.dump(), open(tmp, "w")); os.replace(tmp, s.cfile())
    def load_current(s):
        try: d = json.load(open(s.cfile()))
        except Exception: d = {}
        s.name = d.get("name", "Playlist"); s.defpre = d.get("defpre", 0.0); s.defpost = d.get("defpost", 0.0)
        s.auto = d.get("auto", True); s.loop = d.get("loop", False); s.prefs = d.get("prefs", {}); s.resume = d.get("resume")
        s.items = [s.norm(i) for i in d.get("items", [])] or [mk(p) for p in videos_in(s.folder)]
    def norm(s, it): return {**mk(it.get("path", ""), it.get("kind")), **it}
    def pl_path(s, name): return os.path.join(HOME, "playlists", "".join(c for c in name if c.isalnum() or c in " -_()").strip() + ".json")

    # ---------- mpv ----------
    def kill_orphans(s):
        """Se una copia precedente è stata uccisa di forza, il suo mpv resterebbe aperto sullo schermo: lo chiudiamo."""
        for l in subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout.splitlines():
            m = re.search(r"--input-ipc-server=\S*dolly-(\d+)-\d+\.sock", l)
            if m and int(m.group(1)) != os.getpid():
                try: os.kill(int(m.group(1)), 0)
                except ProcessLookupError: log("chiudo un mpv rimasto aperto:", l.split()[0]); os.kill(int(l.split()[0]), signal.SIGKILL)
                except PermissionError: pass
    def apply_prefs(s):
        cmds = [["set_property", k, v] for k, v in s.prefs.items()]
        if cmds:
            try: s.mpv.ipc(cmds)
            except Exception as e: log("prefs:", e)
    def respawn(s, why):
        log("RIAVVIO mpv:", why); s.restarts += 1
        s.mpv.kill(); s.mpv.start(); s.fails = 0; s.apply_prefs()
        if s.mode == "playing": s.load(s.idx, start=max(0, s.pos - 1))
        elif s.mode == "wait": s.shown = 0
    def pre(s, i): v = s.items[i].get("pre"); return s.defpre if v is None else v
    def post(s, i): v = s.items[i].get("post"); return s.defpost if v is None else v

    # ---------- sequenza ----------
    def load(s, i, start=0):
        it = s.items[i]
        if it["kind"] == "pausa":  # intervallo: schermo nero con testo e conto alla rovescia
            s.mpv.ipc([["stop"]]); s.mode, s.idx, s.sel, s.until, s.shown, s.err = "wait", i, i, time.time() + it["secs"], 0, None
            return
        if not os.path.isfile(it["path"]):
            s.err = f"file mancante: {os.path.basename(it['path'])}"; log(s.err); return s.advance(i)
        # lingue e livello di questo film (le opzioni valgono per il file che sta per essere aperto)
        pre = [["set_property", "alang", it["alang"] or "ita,it,eng,en"], ["set_property", "slang", it["slang"] or ""], ["set_property", "sid", "auto" if it["slang"] else "no"]]
        if it["vol"] is not None: pre.append(["set_property", "volume", float(it["vol"])]); s.prefs["volume"] = float(it["vol"])
        cmd = ["loadfile", it["path"], "replace", -1, f"start={start}"] if start else ["loadfile", it["path"], "replace"]
        s.mpv.ipc(pre + [cmd, ["set_property", "pause", False]])
        s.mode, s.idx, s.sel, s.loaded_at, s.pos, s.dur, s.err = "playing", i, i, time.time(), start, 0, None
        if start == 0: s.retries = 0
    def gap(s, i, secs, label):
        if s.mode in ("playing", "wait"): s.mpv.ipc([["stop"]])
        s.mode, s.next, s.sel, s.until, s.label = "gap", i, i, time.time() + secs, label
        if secs <= 0: s.load(i)
    def stop(s):
        s.mpv.ipc([["stop"]]); s.mode, s.resume = "idle", None; s.save()
    def advance(s, i):
        """Il film i è finito (o saltato): passa al successivo con il nero tra i due."""
        n = i + 1
        if n >= len(s.items):
            if not (s.loop and s.auto and s.items): s.mode, s.resume, s.sel = "idle", None, max(0, min(i, len(s.items) - 1)); s.save(); return
            n = 0
        s.sel = n
        if not s.auto: s.mode, s.resume = "idle", None; s.save(); return
        secs = s.post(i) + s.pre(n)
        s.gap(n, secs, "Nero tra i film" if secs else "")
    def tick(s):
        if s.quitting: return
        if not s.mpv.alive(): return s.respawn("processo terminato")
        now = time.time()
        if s.mode == "gap" and now >= s.until: s.load(s.next)
        elif s.mode == "wait":
            left = s.until - now
            if left <= 0: s.mpv.ipc([["show-text", "", 1]]); return s.advance(s.idx)
            if int(left) != s.shown:  # una volta al secondo: testo + tempo che manca, sullo schermo della sala
                s.shown = int(left); txt = s.items[s.idx]["text"]
                try: s.mpv.ipc([["show-text", (txt + "\n" if txt else "") + f"{int(left) // 60}:{int(left) % 60:02d}", 1500]])
                except Exception: pass
        elif s.mode == "playing":
            try: r = s.mpv.get("idle-active", "time-pos", "duration"); s.fails = 0
            except Exception as e:
                s.fails += 1; log("mpv non risponde", s.fails, e)
                if s.fails >= 3: s.respawn("non risponde")
                return
            if r["idle-active"]:
                if now - s.loaded_at < 2: return  # caricamento in corso
                if s.dur and s.pos < s.dur - 5 and s.retries < 2:  # fine anomala: riprova dal punto in cui era
                    s.retries += 1; msg = f"interrotto a {int(s.pos)}s, riprendo"; log(msg); s.load(s.idx, start=max(0, s.pos - 1)); s.err = msg
                else:
                    if not s.dur: s.err = f"{os.path.basename(s.items[s.idx]['path'])}: non riproducibile, passo oltre"
                    s.advance(s.idx)
            else:
                s.pos, s.dur = r["time-pos"] or s.pos, r["duration"] or s.dur
                if now - s.last_save > 2: s.last_save = now; s.resume = {"idx": s.idx, "pos": s.pos, "t": time.time()}; s.save()
    def run(s):
        while True:
            try:
                with s.lock: s.tick()
            except Exception as e: log("errore tick:", repr(e))
            time.sleep(.25)

    # ---------- comandi dal telecomando ----------
    def base(s): return s.idx if s.mode in ("playing", "wait") else s.sel
    def act(s, d):
        a = d.get("a")
        with s.lock:
            if a == "play": s.start_item(int(d["i"]))
            elif a == "toggle":  # play/pausa: se non sta suonando niente parte l'elemento selezionato
                if s.mode == "playing": s.mpv.ipc([["cycle", "pause"]])
                elif s.mode == "idle": s.start_item(s.sel)
            elif a == "skipgap" and s.mode == "gap": s.load(s.next)
            elif a == "skipgap" and s.mode == "wait": s.mpv.ipc([["show-text", "", 1]]); s.advance(s.idx)
            elif a == "extend" and s.mode == "wait": s.until += float(d.get("v", 60))  # intervallo più lungo
            elif a == "next": s.start_item(s.base() + 1)
            elif a == "prev": s.start_item(s.base() - 1)
            elif a == "stop": s.stop()
            elif a == "resume" and s.resume and s.resume["idx"] < len(s.items): s.load(s.resume["idx"], start=s.resume["pos"])
            elif a == "seek": s.mpv.ipc([["seek", float(d["v"]), d.get("m", "absolute")]])
            elif a in ("frame", "frameback"): s.mpv.ipc([["frame-step" if a == "frame" else "frame-back-step"]])
            elif a == "abloop": s.mpv.ipc([["ab-loop"]])
            elif a == "chapter": s.mpv.ipc([["set_property", "chapter", int(d["v"])]])
            elif a in ("aid", "sid", "vid"): s.mpv.ipc([["set_property", a, d["v"] if d["v"] in ("no", "auto") else int(d["v"])]])
            elif a == "set": s.set_prop(d["p"], d["v"])
            elif a == "setmany":
                for p, v in d["props"].items(): s.set_prop(p, v)
            elif a == "text": s.mpv.ipc([["show-text", str(d["v"])[:200], int(d.get("ms", 5000))]])
            elif a == "resetvideo":
                for p in ("brightness", "contrast", "saturation", "gamma", "hue", "video-zoom", "video-pan-x", "video-pan-y", "panscan"): s.set_prop(p, 0)
                s.set_prop("video-aspect-override", "-1")
            elif a == "defaults":
                for k in ("defpre", "defpost"):
                    if k in d: setattr(s, k, max(0.0, float(d[k])))
                for k in ("auto", "loop"):
                    if k in d: setattr(s, k, bool(d[k]))
            elif a == "add": s.items += [mk(p) for x in d["paths"] for p in videos_in(os.path.expanduser(x))]
            elif a == "addpause": s.items.append(mk("", "pausa", secs=max(1.0, float(d.get("secs", 600))), text=str(d.get("text", "Intervallo"))[:100]))
            elif a == "addlib":
                fs = s.folder_files(); fs = [fs[int(d["i"])]] if "i" in d else fs
                s.items += [mk(p) for p in fs]
            elif a == "remove": s.remove(int(d["i"]))
            elif a == "move": s.move(int(d["i"]), int(d["d"]))
            elif a == "clear":
                if s.mode != "idle": s.stop()
                s.items, s.sel, s.idx = [], 0, -1
            elif a == "setitem":
                it = s.items[int(d["i"])]
                for k in ("pre", "post", "vol"):
                    if k in d: it[k] = None if d[k] in (None, "") else max(0.0, float(d[k]))
                if "secs" in d: it["secs"] = max(1.0, float(d["secs"]))
                for k in ("alang", "slang", "text"):
                    if k in d: it[k] = str(d[k])[:100]
            elif a == "rename": s.name = str(d["v"])[:60]
            elif a == "pl_save": s.name = str(d.get("name") or s.name)[:60]; json.dump(s.dump(), open(s.pl_path(s.name), "w"))
            elif a == "pl_load": s.pl_load(d["name"])
            elif a == "pl_delete":
                try: os.remove(s.pl_path(d["name"]))
                except OSError: pass
            elif a == "pl_import": s.import_m3u(d["path"])
            elif a == "quit": s.quitting = True; s.mpv.kill(); threading.Thread(target=lambda: (time.sleep(.3), os._exit(0))).start()
            s.save()
    def start_item(s, i):
        if 0 <= i < len(s.items): s.gap(i, s.pre(i), "Nero prima del film" if s.pre(i) else "")
    def set_prop(s, p, v):
        k = PROPS[p]
        v = bool(v) if k[0] == "b" else max(k[1], min(k[2], float(v))) if k[0] == "f" else str(v)[:100]
        if p.endswith("color") and not re.fullmatch(r"#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})", v): raise ValueError(f"colore non valido: {v}")
        if p == "sub-ass-override" and v not in ("no", "yes", "scale", "force", "strip"): raise ValueError(v)
        s.prefs[p] = v; s.mpv.ipc([["set_property", p, v]])
    def remove(s, i):
        if not 0 <= i < len(s.items): return
        del s.items[i]
        if s.idx == i and s.mode in ("playing", "wait"): s.stop()
        elif s.idx > i: s.idx -= 1
        if s.mode == "gap" and s.next == i: s.stop()
        elif s.next > i: s.next -= 1
        s.sel = min(s.sel if s.sel <= i else s.sel - 1, max(0, len(s.items) - 1))
    def move(s, i, dlt):
        j = i + dlt
        if 0 <= i < len(s.items) and 0 <= j < len(s.items):
            s.items[i], s.items[j] = s.items[j], s.items[i]
            for n in ("idx", "next", "sel"):
                v = getattr(s, n); setattr(s, n, j if v == i else i if v == j else v)
    def pl_load(s, name):
        d = json.load(open(s.pl_path(name)))
        if s.mode != "idle": s.stop()
        s.name, s.items, s.defpre, s.defpost = d["name"], [s.norm(i) for i in d["items"]], d.get("defpre", 0.0), d.get("defpost", 0.0)
        s.auto, s.loop, s.idx, s.sel = d.get("auto", True), d.get("loop", False), -1, 0
    def import_m3u(s, path):
        base, out = os.path.dirname(path), []
        for l in open(path, encoding="utf8", errors="ignore"):
            l = l.strip()
            if l and not l.startswith("#"): out.append(l if os.path.isabs(l) else os.path.join(base, l))
        if s.mode != "idle": s.stop()
        s.name, s.idx, s.sel = os.path.splitext(os.path.basename(path))[0], -1, 0
        s.items = [mk(p) for x in out for p in videos_in(x)]
    def folder_files(s): return videos_in(s.folder)
    def preview(s):
        """JPEG di ciò che si vede ora sullo schermo della sala (None se è nero). Al massimo ~2 al secondo, in cache."""
        with s.lock:
            if s.mode != "playing": return None
            if time.time() - s.pv_t < .45: return s.pv
            f = os.path.join(tempfile.gettempdir(), f"dolly-{os.getpid()}-preview.jpg")
            try: s.mpv.ipc([["screenshot-to-file", f, "window"]]); s.pv = open(f, "rb").read()
            except Exception: s.pv = None
            s.pv_t = time.time(); return s.pv

    # ---------- stato per la pagina ----------
    def state(s):
        with s.lock:
            st = {"ok": True, "name": s.name, "mode": s.mode, "idx": s.idx, "sel": s.sel, "next": s.next, "label": s.label,
                  "left": max(0, round(s.until - time.time(), 1)) if s.mode in ("gap", "wait") else 0, "err": s.err, "restarts": s.restarts,
                  "auto": s.auto, "loop": s.loop, "defpre": s.defpre, "defpost": s.defpost, "resume": s.resume, "folder": s.folder,
                  "items": [{**{k: i[k] for k in ("kind", "pre", "post", "vol", "alang", "slang", "secs", "text")}, "name": os.path.basename(i["path"]) or i["text"] or "Pausa", "ok": i["kind"] == "pausa" or os.path.isfile(i["path"])} for i in s.items],
                  "lib": [os.path.basename(p) for p in s.folder_files()],
                  "saved": sorted(f[:-5] for f in os.listdir(os.path.join(HOME, "playlists")) if f.endswith(".json"))}
            try:
                r = s.mpv.get("pause", "time-pos", "duration", "track-list", "chapter-list", "chapter", "ab-loop-a", "ab-loop-b", "video-params",
                              "container-fps", "video-codec", "audio-codec-name", "frame-drop-count", "decoder-frame-drop-count", "path", "audio-device-list", *READ)
            except Exception as e: st.update(ok=False, err=f"mpv non risponde: {e}"); return st
            tl = r["track-list"] or []
            tr = lambda t: [{"id": x["id"], "t": " · ".join(str(y) for y in (x.get("lang"), x.get("title"), x.get("codec"), x.get("demux-channel-count") and f"{x['demux-channel-count']}ch") if y) or f"traccia {x['id']}", "sel": bool(x.get("selected"))} for x in tl if x["type"] == t]
            vp = r["video-params"] or {}
            st.update(playing=r["path"] is not None, pause=r["pause"], time=r["time-pos"] or 0, dur=r["duration"] or 0, audio=tr("audio"), sub=tr("sub"), video=tr("video"),
                      chapters=[{"t": c.get("title") or f"Capitolo {i + 1}", "s": c["time"]} for i, c in enumerate(r["chapter-list"] or [])], chapter=r["chapter"],
                      ab=[r["ab-loop-a"], r["ab-loop-b"]], props={k: r[k] for k in READ}, adevs=[{"id": d["name"], "t": d.get("description") or d["name"]} for d in r["audio-device-list"] or []],
                      info={"res": f"{vp.get('w')}×{vp.get('h')}" if vp else "", "fps": r["container-fps"], "vcodec": r["video-codec"], "acodec": r["audio-codec-name"],
                            "dropped": (r["frame-drop-count"] or 0) + (r["decoder-frame-drop-count"] or 0)})
            return st

def serve(p, port):
    page = lambda: open(os.path.join(HERE, "remote.html"), encoding="utf8").read().encode()
    class H(BaseHTTPRequestHandler):
        def log_message(s, *a): pass
        def send(s, body, ct):
            s.send_response(200); s.send_header("Content-Type", ct); s.send_header("Cache-Control", "no-store"); s.end_headers(); s.wfile.write(body)
        def do_GET(s):
            if s.path == "/api/state": s.send(json.dumps(p.state()).encode(), "application/json")
            elif s.path.startswith("/api/preview"):
                j = p.preview()
                if j: s.send(j, "image/jpeg")
                else: s.send_response(204); s.end_headers()
            else: s.send(page(), "text/html; charset=utf-8")
        def do_POST(s):
            body = json.loads(s.rfile.read(int(s.headers.get("Content-Length", 0)) or 0) or b"{}"); out = {}
            try:
                if s.path == "/api/pick": out = {"paths": pick(body["kind"])}
                else: p.act(body)
            except Exception as e: log("errore comando", body, repr(e)); out = {"error": repr(e)}
            s.send(json.dumps(out).encode(), "application/json")
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()  # solo localhost: nessun altro sulla rete può comandare il player

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default="~/Desktop/Opere Prime/Film")
    ap.add_argument("--screen", type=int, default=1); ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--windowed", action="store_true"); ap.add_argument("--open", action="store_true", help="apri il telecomando nel browser"); ap.add_argument("--autoresume", action="store_true", help="dopo un riavvio imprevisto riprende il film in corso"); ap.add_argument("--mpv", default="", help="opzioni mpv extra (per prove)")
    a = ap.parse_args()
    if not os.path.isdir(os.path.expanduser(a.folder)): sys.exit(f"cartella non trovata: {a.folder}")
    p = Player(a)
    atexit.register(lambda: (p.mpv.kill(), p.caff and p.caff.terminate()))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print(f"{len(p.items)} film in playlist\nTelecomando: http://127.0.0.1:{a.port}  (Ctrl+C per chiudere tutto)", flush=True)
    if a.open: threading.Timer(.5, lambda: webbrowser.open(f"http://127.0.0.1:{a.port}")).start()
    try: serve(p, a.port)
    except KeyboardInterrupt: pass

if __name__ == "__main__": main()
