#!/usr/bin/env python3
"""Costruisce DCP di prova per test_dolly.py (-k dcp): file MXF veri (JPEG 2000 profilo "cinema 2K" in XYZ, audio PCM 24 bit a 6 canali) con ASSETMAP e CPL scritti a mano.

  ./tools/make_test_dcp.py CARTELLA_DI_USCITA

Servono ffmpeg e asdcp-test (asdcplib: https://github.com/cinecert/asdcplib; se non è nel PATH: ASDCP_TEST=/percorso/asdcp-test).
Pacchetti creati (ognuno in una sottocartella):
  smpte_2reel   SMPTE, 2 reel da 2 s, audio 5.1, sottotitoli SMPTE in MXF (uno per reel), titolo "Dolly Test SMPTE"
  interop_1reel Interop (ASSETMAP senza .xml), 1 reel da 2 s, sottotitoli Interop in XML, titolo "Dolly Test Interop"
  multi_cpl     un pacchetto con due CPL (due versioni dello stesso film): "Versione Uno" e "Versione Due"
  cifrato       CPL con <KeyId> (DCP cifrato): non si deve poter proiettare
  incompleto    CPL che cita un MXF che non esiste
"""
import glob, os, shutil, subprocess, sys, uuid

ASD = os.environ.get("ASDCP_TEST", "asdcp-test")
OUT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
W = os.path.join(OUT, "_work")
FPS = 24
def uid(): return "urn:uuid:" + str(uuid.uuid4())
def run(*a): subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def frames(n, src, secs=2):
    d = os.path.join(W, f"fr{n}"); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    run("ffmpeg", "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", f"{src}=size=1998x1080:rate={FPS}:duration={secs}", "-vf", "format=xyz12le",
        "-c:v", "jpeg2000", "-format", "j2k", "-pix_fmt", "xyz12le", os.path.join(d, "f%05d.j2k"))
    for f in glob.glob(d + "/*.j2k"):   # Rsiz = 3: profilo "digital cinema 2K", che fa riconoscere lo spazio colore XYZ
        b = bytearray(open(f, "rb").read()); b[6:8] = (3).to_bytes(2, "big"); open(f, "wb").write(b)
    return d

def wav(n, freq, secs=2):
    p = os.path.join(W, f"a{n}.wav")
    run("ffmpeg", "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i",
        f"aevalsrc=sin(2*PI*{freq}*t)|sin(2*PI*({freq}+110)*t)|sin(2*PI*({freq}+220)*t)|0|sin(2*PI*({freq}/2)*t)|sin(2*PI*({freq}/3)*t):s=48000:d={secs}:c=5.1", "-c:a", "pcm_s24le", p)
    return p

def wrap(kind_args, dest, src):
    run(ASD, *kind_args, "-c", dest, src)

INTEROP_SUB = """<?xml version="1.0" encoding="UTF-8"?>
<DCSubtitle Version="1.0"><SubtitleID>{id}</SubtitleID><MovieTitle>Dolly Test</MovieTitle><ReelNumber>1</ReelNumber><Language>Italian</Language>
<Font Id="Font1" Size="42" Weight="normal" Color="FFFFFFFF"><Subtitle SpotNumber="1" TimeIn="00:00:01:125" TimeOut="00:00:01:240" FadeUpTime="00:00:00:001" FadeDownTime="00:00:00:001"><Text VAlign="bottom" VPosition="8">Ciao dal DCP Interop</Text></Subtitle>
<Subtitle SpotNumber="2" TimeIn="00:00:01:240" TimeOut="00:00:01:249" FadeUpTime="00:00:00:001" FadeDownTime="00:00:00:001"><Text VAlign="bottom" VPosition="8">Seconda riga</Text><Text VAlign="bottom" VPosition="16">e terza</Text></Subtitle></Font></DCSubtitle>
"""
SMPTE_SUB = """<?xml version="1.0" encoding="UTF-8"?>
<SubtitleReel xmlns="http://www.smpte-ra.org/schemas/428-7/2010/DCST"><Id>{id}</Id><ContentTitleText>Dolly Test</ContentTitleText><AnnotationText>Dolly</AnnotationText><IssueDate>2026-10-15T10:00:00.000+00:00</IssueDate>
<ReelNumber>{reel}</ReelNumber><Language>it</Language><EditRate>24 1</EditRate><TimeCodeRate>24</TimeCodeRate><StartTime>00:00:00:00</StartTime>
<SubtitleList><Font Size="42" Color="FFFFFFFF"><Subtitle SpotNumber="1" TimeIn="{tin}" TimeOut="{tout}" FadeUpTime="00:00:00:01" FadeDownTime="00:00:00:01"><Text Valign="bottom" Vposition="8">{text}</Text></Subtitle></Font></SubtitleList></SubtitleReel>
"""

def cpl_xml(ns, title, reels, key=False):
    """reels: lista di (picId, sndId|None, subId|None, durata in fotogrammi)."""
    kid = "<KeyId>urn:uuid:00000000-0000-0000-0000-000000000001</KeyId>" if key else ""
    def a(tag, i, d, extra=""): return f"<{tag}><Id>{i}</Id><EditRate>{FPS} 1</EditRate><IntrinsicDuration>{d}</IntrinsicDuration><EntryPoint>0</EntryPoint><Duration>{d}</Duration>{extra}{kid if tag != 'MainSubtitle' else ''}</{tag}>"
    rl = ""
    for pic, snd, sub, d in reels:
        rl += f"<Reel><Id>{uid()}</Id><AssetList>" + a("MainPicture", pic, d, f"<FrameRate>{FPS} 1</FrameRate><ScreenAspectRatio>1998 1080</ScreenAspectRatio>")
        if snd: rl += a("MainSound", snd, d)
        if sub: rl += a("MainSubtitle", sub, d)
        rl += "</AssetList></Reel>"
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<CompositionPlaylist xmlns="{ns}"><Id>{uid()}</Id><AnnotationText>{title}</AnnotationText><IssueDate>2026-10-15T10:00:00+00:00</IssueDate>'
            f'<Issuer>Dolly</Issuer><Creator>make_test_dcp</Creator><ContentTitleText>{title}</ContentTitleText><ContentKind>feature</ContentKind><RatingList/><ReelList>{rl}</ReelList></CompositionPlaylist>\n')

def assetmap(path, ns, files):
    """files: lista di (id, nome file)."""
    al = "".join(f"<Asset><Id>{i}</Id><ChunkList><Chunk><Path>{n}</Path><VolumeIndex>1</VolumeIndex><Offset>0</Offset><Length>{os.path.getsize(os.path.join(os.path.dirname(path), n)) if os.path.exists(os.path.join(os.path.dirname(path), n)) else 0}</Length></Chunk></ChunkList></Asset>" for i, n in files)
    open(path, "w").write(f'<?xml version="1.0" encoding="UTF-8"?>\n<AssetMap xmlns="{ns}"><Id>{uid()}</Id><Creator>make_test_dcp</Creator><VolumeCount>1</VolumeCount><IssueDate>2026-10-15T10:00:00+00:00</IssueDate><Issuer>Dolly</Issuer><AssetList>{al}</AssetList></AssetMap>\n')

SMPTE_CPL, SMPTE_AM = "http://www.smpte-ra.org/schemas/429-7/2006/CPL", "http://www.smpte-ra.org/schemas/429-9/2007/AM"
IOP_CPL, IOP_AM = "http://www.digicine.com/PROTO-ASDCP-CPL-20040511#", "http://www.digicine.com/PROTO-ASDCP-AM-20040311#"

def main():
    shutil.rmtree(OUT, ignore_errors=True); os.makedirs(W)
    f1, f2 = frames(1, "smptebars"), frames(2, "rgbtestsrc"); a1, a2 = wav(1, 440), wav(2, 660)
    # --- SMPTE, 2 reel
    d = os.path.join(OUT, "smpte_2reel"); os.makedirs(d); files = []
    ids = {k: uid() for k in ("v1", "v2", "a1", "a2", "s1", "s2")}
    for n, fr, au in ((1, f1, a1), (2, f2, a2)):
        wrap(["-L", "-p", str(FPS)], os.path.join(d, f"video{n}.mxf"), fr); wrap(["-L"], os.path.join(d, f"audio{n}.mxf"), au)
        files += [(ids[f"v{n}"], f"video{n}.mxf"), (ids[f"a{n}"], f"audio{n}.mxf")]
    for n, (tin, tout, text) in ((1, ("00:00:01:00", "00:00:01:20", "Uno SMPTE")), (2, ("00:00:00:12", "00:00:01:12", "Due SMPTE"))):
        x = os.path.join(W, f"sub{n}.xml"); open(x, "w").write(SMPTE_SUB.format(id=uid(), reel=n, tin=tin, tout=tout, text=text))
        wrap(["-L"], os.path.join(d, f"sub{n}.mxf"), x); files.append((ids[f"s{n}"], f"sub{n}.mxf"))
    cpl = f"CPL_{uuid.uuid4()}.xml"; open(os.path.join(d, cpl), "w").write(cpl_xml(SMPTE_CPL, "Dolly Test SMPTE", [(ids["v1"], ids["a1"], ids["s1"], 48), (ids["v2"], ids["a2"], ids["s2"], 48)]))
    files.append((uid(), cpl)); assetmap(os.path.join(d, "ASSETMAP.xml"), SMPTE_AM, files)
    # --- Interop, 1 reel, sottotitoli in XML
    d = os.path.join(OUT, "interop_1reel"); os.makedirs(d); ids = {k: uid() for k in ("v", "a", "s")}
    wrap(["-p", str(FPS)], os.path.join(d, "video.mxf"), f1); wrap([], os.path.join(d, "audio.mxf"), a1)
    open(os.path.join(d, "sub.xml"), "w").write(INTEROP_SUB.format(id=uid()))
    cpl = f"cpl_{uuid.uuid4()}.xml"; open(os.path.join(d, cpl), "w").write(cpl_xml(IOP_CPL, "Dolly Test Interop", [(ids["v"], ids["a"], ids["s"], 48)]))
    assetmap(os.path.join(d, "ASSETMAP"), IOP_AM, [(ids["v"], "video.mxf"), (ids["a"], "audio.mxf"), (ids["s"], "sub.xml"), (uid(), cpl)])
    # --- due CPL nello stesso pacchetto (stessi file, titoli diversi)
    d = os.path.join(OUT, "multi_cpl"); os.makedirs(d); ids = {k: uid() for k in ("v", "a")}
    wrap(["-L", "-p", str(FPS)], os.path.join(d, "video.mxf"), f2); wrap(["-L"], os.path.join(d, "audio.mxf"), a2)
    c1, c2 = f"CPL_{uuid.uuid4()}.xml", f"CPL_{uuid.uuid4()}.xml"
    open(os.path.join(d, c1), "w").write(cpl_xml(SMPTE_CPL, "Versione Uno", [(ids["v"], ids["a"], None, 48)]))
    open(os.path.join(d, c2), "w").write(cpl_xml(SMPTE_CPL, "Versione Due", [(ids["v"], ids["a"], None, 24)]))
    assetmap(os.path.join(d, "ASSETMAP.xml"), SMPTE_AM, [(ids["v"], "video.mxf"), (ids["a"], "audio.mxf"), (uid(), c1), (uid(), c2)])
    # --- cifrato (il contenuto non conta: Dolly si ferma al <KeyId>)
    d = os.path.join(OUT, "cifrato"); os.makedirs(d); ids = {k: uid() for k in ("v", "a")}
    shutil.copy(os.path.join(OUT, "multi_cpl", "video.mxf"), d); shutil.copy(os.path.join(OUT, "multi_cpl", "audio.mxf"), d)
    cpl = f"CPL_{uuid.uuid4()}.xml"; open(os.path.join(d, cpl), "w").write(cpl_xml(SMPTE_CPL, "Dolly Test Cifrato", [(ids["v"], ids["a"], None, 48)], key=True))
    assetmap(os.path.join(d, "ASSETMAP.xml"), SMPTE_AM, [(ids["v"], "video.mxf"), (ids["a"], "audio.mxf"), (uid(), cpl)])
    # --- incompleto: il CPL cita un video che non c'è
    d = os.path.join(OUT, "incompleto"); os.makedirs(d); ids = {k: uid() for k in ("v", "a")}
    shutil.copy(os.path.join(OUT, "multi_cpl", "audio.mxf"), d)
    cpl = f"CPL_{uuid.uuid4()}.xml"; open(os.path.join(d, cpl), "w").write(cpl_xml(SMPTE_CPL, "Dolly Test Incompleto", [(ids["v"], ids["a"], None, 48)]))
    assetmap(os.path.join(d, "ASSETMAP.xml"), SMPTE_AM, [(ids["v"], "manca_il_video.mxf"), (ids["a"], "audio.mxf"), (uid(), cpl)])
    shutil.rmtree(W)
    print("DCP di prova in", OUT, "—", ", ".join(sorted(os.listdir(OUT))))

main()
