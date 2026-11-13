"""Round 3: Dolly E migliorata (bobina vera, non disco del telefono); Booth E con check piccolo."""
import io, math, sys, os, importlib.util
spec = importlib.util.spec_from_file_location("g2", os.path.join(os.path.dirname(__file__), "genera2.py"))
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
sys.argv = [sys.argv[0], OUT + "/_tmp"]
g2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(g2)
from PIL import Image, ImageDraw
svg, d_path, render, font = g2.svg, g2.d_path, g2.render, g2.font


def sector(cx, cy, r1, r2, a0, a1):
    a0, a1 = math.radians(a0), math.radians(a1)
    p = lambda r, a: f"{cx + r*math.cos(a):.1f},{cy + r*math.sin(a):.1f}"
    return f"M{p(r1,a0)} L{p(r2,a0)} A{r2},{r2} 0 0 1 {p(r2,a1)} L{p(r1,a1)} A{r1},{r1} 0 0 0 {p(r1,a0)} Z"


def dolly(variant):
    cx, cy, R = 470, 470, 330
    cut = "#141416"
    n = 3 if variant == "a" else 5
    gap = 34 if n == 3 else 22
    cuts = "".join(f'<path d="{sector(cx, cy, 150, 262, -90 + i*360/n + gap, -90 + (i+1)*360/n - gap)}" fill="{cut}" stroke="{cut}" stroke-width="36" stroke-linejoin="round"/>' for i in range(n))
    # pellicola che si svolge dal bordo della bobina verso l'angolo in basso a destra
    film = '''<path d="M640,760 C720,770 800,820 1060,930 L1060,1060 L560,1060 C600,940 610,840 640,760 Z" fill="#141416"/>'''
    strip = '''<g transform="rotate(28 800 880)"><rect x="560" y="800" width="560" height="170" fill="#2A1D12"/>
''' + "".join(f'<rect x="{x}" y="814" width="30" height="24" rx="6" fill="#E3A93C"/><rect x="{x}" y="932" width="30" height="24" rx="6" fill="#E3A93C"/>' for x in range(580, 1120, 58)) + '''
''' + "".join(f'<rect x="{x}" y="850" width="96" height="70" rx="6" fill="#4A3522"/>' for x in range(590, 1120, 116)) + '</g>'
    b = f'''<rect width="1024" height="1024" fill="url(#blackbg)"/>
{strip}
<circle cx="{cx}" cy="{cy}" r="{R}" fill="url(#gold)"/>
<circle cx="{cx}" cy="{cy}" r="{R-22}" fill="none" stroke="#7A4A10" stroke-width="8" opacity=".45"/>
{cuts}
<circle cx="{cx}" cy="{cy}" r="118" fill="url(#gold)"/>
<circle cx="{cx}" cy="{cy}" r="100" fill="{cut}"/>
<path d="{d_path(cx-50, cy, 132, 72, 30)}" fill="#F4F2EC"/>
<path d="{d_path(cx-18, cy, 62, 36, 0)}" fill="{cut}"/>'''
    return svg("", b)


def booth(check_scale):
    cx, cy, r = 450, 450, 245
    defs = '<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFD54A"/><stop offset="1" stop-color="#F5A623"/></linearGradient>' + f'<clipPath id="glassclip"><circle cx="{cx}" cy="{cy}" r="{r}"/></clipPath>'
    k = check_scale
    film = f'''<g clip-path="url(#glassclip)"><rect x="150" y="{cy-120}" width="620" height="240" fill="#F2B632"/>
{"".join(f'<rect x="{x}" y="{cy-102}" width="34" height="30" rx="7" fill="#FFE68A"/><rect x="{x}" y="{cy+72}" width="34" height="30" rx="7" fill="#FFE68A"/>' for x in range(190, 760, 70))}</g>'''
    pts = [(-110, 5), (-30, 85), (120, -75)]
    pl = " ".join(f"{cx + x*k:.0f},{cy + 10*k + y*k:.0f}" for x, y in pts)
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<g transform="rotate(-45 {cx} {cy})"><rect x="{cx-62}" y="{cy+r+10}" width="124" height="290" rx="62" fill="#16161A"/></g>
<circle cx="{cx}" cy="{cy}" r="{r}" fill="#FFE68A"/>
{film}
<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#16161A" stroke-width="64"/>
<polyline points="{pl}" fill="none" stroke="#16161A" stroke-width="{max(30, 64*k):.0f}" stroke-linecap="round" stroke-linejoin="round"/>'''
    return svg(defs, b)


P = {"Dolly": [("G - 3 finestre", lambda: dolly("a")), ("H - 5 finestre", lambda: dolly("b"))],
     "Booth": [("G - check 50%", lambda: booth(.5)), ("H - check 40%", lambda: booth(.4))]}
icons = {}
for app, lst in P.items():
    for lab, fn in lst:
        s = fn(); key = f"{app} {lab[0]}"
        open(f"{OUT}/{key}.svg", "w").write(s); im = render(s); im.save(f"{OUT}/{key}.png"); icons[(app, lab)] = im
CW, PAD = 330, 30
rows = []
for bg in [(236, 236, 236), (30, 30, 34)]:
    row = Image.new("RGB", (CW * 4 + PAD, 380), bg); d = ImageDraw.Draw(row)
    fg = (20, 20, 20) if bg[0] > 128 else (235, 235, 235)
    i = 0
    for app, lst in P.items():
        for lab, _ in lst:
            im = icons[(app, lab)]; x = PAD + i * CW
            d.text((x, 18), f"{app} {lab}", fill=fg, font=font(20))
            big = im.resize((256, 256), Image.LANCZOS); row.paste(big, (x, 52), big)
            xx = x
            for sz in (64, 32, 16):
                sm = im.resize((sz, sz), Image.LANCZOS); row.paste(sm, (xx, 320 + (64 - sz) // 2 - 10), sm); xx += sz + 18
            i += 1
    rows.append(row)
board = Image.new("RGB", (rows[0].width, sum(r.height for r in rows))); y = 0
for r in rows: board.paste(r, (0, y)); y += r.height
board.save(f"{OUT}/tavola_confronto_3.png"); print("ok")
