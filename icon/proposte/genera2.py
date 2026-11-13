"""Round 2: Dolly = bobina + D + nero; Booth = lente semplificata, colori nuovi."""
import io, math, sys, os
import cairosvg
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def squircle(x0=100, y0=100, size=824, n=5.0, steps=360):
    r = size / 2
    cx, cy = x0 + r, y0 + r
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + r * math.copysign(abs(c) ** (2 / n), c), cy + r * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


TILE = squircle()


def svg(defs, body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><clipPath id="tile"><path d="{TILE}"/></clipPath>
<linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".12"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE29A"/><stop offset=".55" stop-color="#E3A93C"/><stop offset="1" stop-color="#A86A1C"/></linearGradient>
<linearGradient id="blackbg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#26262A"/><stop offset="1" stop-color="#0D0D0F"/></linearGradient>
{defs}</defs>
<path d="{TILE}" fill="#000" opacity=".22" transform="translate(0,10)"/>
<g clip-path="url(#tile)">{body}<rect width="1024" height="1024" fill="url(#gloss)"/></g>
<path d="{TILE}" fill="none" stroke="#000" stroke-opacity=".18" stroke-width="2"/>
</svg>'''


def holes(cx, cy, rad, r, n, fill, start=-90, span=360):
    out = []
    for i in range(n):
        a = math.radians(start + span * i / n)
        out.append(f'<circle cx="{cx + rad*math.cos(a):.1f}" cy="{cy + rad*math.sin(a):.1f}" r="{r}" fill="{fill}"/>')
    return "".join(out)


def d_path(x0, cy, h, bowl_r, stem_w):
    """Silhouette di una D: montante + semicerchio."""
    top, bot = cy - h / 2, cy + h / 2
    sx = x0 + stem_w
    return (f"M{x0},{top} L{sx},{top} A{bowl_r},{h/2} 0 0 1 {sx},{bot} L{x0},{bot} Z")


# ---------- DOLLY ----------
def dolly_1():
    """D-bobina: il montante bianco e la pancia della D è mezza bobina dorata."""
    cx, cy, R = 400, 512, 300
    clip = f'<clipPath id="half"><rect x="{cx}" y="0" width="1024" height="1024"/></clipPath>'
    b = f'''<rect width="1024" height="1024" fill="url(#blackbg)"/>
<g clip-path="url(#half)">
<circle cx="{cx}" cy="{cy}" r="{R}" fill="url(#gold)"/>
<circle cx="{cx}" cy="{cy}" r="{R-34}" fill="none" stroke="#FFF2C4" stroke-width="6" opacity=".5"/>
{holes(cx, cy, 170, 62, 6, "#141416", start=-60, span=360)}
</g>
<rect x="{cx-150}" y="{cy-R}" width="150" height="{2*R}" rx="10" fill="#F4F2EC"/>
<circle cx="{cx}" cy="{cy}" r="44" fill="#141416"/><circle cx="{cx}" cy="{cy}" r="18" fill="url(#gold)"/>
<circle cx="815" cy="235" r="44" fill="#E0352B"/>'''
    return svg(clip, b)


def dolly_2():
    """Bobina dorata su nero, con una D bianca nel mozzo."""
    cx, cy, R = 512, 500, 330
    b = f'''<rect width="1024" height="1024" fill="url(#blackbg)"/>
<rect x="0" y="830" width="1024" height="200" fill="#8E1B1F"/>
<circle cx="{cx}" cy="{cy}" r="{R}" fill="url(#gold)"/>
<circle cx="{cx}" cy="{cy}" r="{R-34}" fill="none" stroke="#FFF2C4" stroke-width="6" opacity=".5"/>
{holes(cx, cy, 225, 62, 6, "#141416", start=-90)}
<circle cx="{cx}" cy="{cy}" r="140" fill="#141416"/>
<path d="{d_path(cx-62, cy, 170, 92, 40)}" fill="#F4F2EC"/>
<path d="{d_path(cx-22, cy, 82, 46, 0)}" fill="#141416"/>'''
    return svg("", b)


def dolly_3():
    """D rossa piena su nero; nel vuoto della D gira la bobina dorata."""
    cx, cy = 470, 512
    b = f'''<rect width="1024" height="1024" fill="url(#blackbg)"/>
<path d="{d_path(220, cy, 620, 330, 160)}" fill="#C9252C"/>
<circle cx="{cx+40}" cy="{cy}" r="185" fill="#141416"/>
<circle cx="{cx+40}" cy="{cy}" r="160" fill="url(#gold)"/>
{holes(cx+40, cy, 92, 36, 6, "#141416")}
<circle cx="{cx+40}" cy="{cy}" r="24" fill="#141416"/>'''
    return svg("", b)


# ---------- BOOTH ----------
def lens(bg_defs, bg_fill, ring, glass, check, handle, perf=None, strip=None):
    cx, cy, r = 450, 450, 245
    film = ""
    if strip:
        film = f'''<g clip-path="url(#glassclip)"><rect x="150" y="{cy-120}" width="620" height="240" fill="{strip}"/>
{"".join(f'<rect x="{x}" y="{cy-102}" width="34" height="30" rx="7" fill="{perf}"/><rect x="{x}" y="{cy+72}" width="34" height="30" rx="7" fill="{perf}"/>' for x in range(190, 760, 70))}</g>'''
    d = bg_defs + f'<clipPath id="glassclip"><circle cx="{cx}" cy="{cy}" r="{r}"/></clipPath>'
    b = f'''<rect width="1024" height="1024" fill="{bg_fill}"/>
<g transform="rotate(-45 {cx} {cy})"><rect x="{cx-62}" y="{cy+r+10}" width="124" height="290" rx="62" fill="{handle}"/></g>
<circle cx="{cx}" cy="{cy}" r="{r}" fill="{glass}"/>
{film}
<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{ring}" stroke-width="64"/>
<polyline points="{cx-110},{cy+5} {cx-30},{cy+85} {cx+120},{cy-75}" fill="none" stroke="{check}" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>'''
    return svg(d, b)


def booth_1():
    return lens('<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#6B4CFF"/><stop offset="1" stop-color="#2B1690"/></linearGradient>',
                "url(#bg)", "#FFFFFF", "#3A23B8", "#B6F25A", "#FFFFFF", perf="#6B4CFF", strip="#22126E")


def booth_2():
    return lens('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFD54A"/><stop offset="1" stop-color="#F5A623"/></linearGradient>',
                "url(#bg)", "#16161A", "#FFE68A", "#16161A", "#16161A", perf="#FFE68A", strip="#F2B632")


def booth_3():
    return lens('<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2F7BFF"/><stop offset="1" stop-color="#0A3FB0"/></linearGradient>',
                "url(#bg)", "#FFFFFF", "#1450D0", "#FFFFFF", "#FFFFFF", perf="#2F7BFF", strip="#0B3591")


PROPOSTE = {
    "Dolly": [("D - D-bobina", dolly_1), ("E - D nel mozzo", dolly_2), ("F - Bobina nella D", dolly_3)],
    "Booth": [("D - Lente viola", booth_1), ("E - Lente gialla", booth_2), ("F - Lente blu", booth_3)],
}


def render(s):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=s.encode(), output_width=1024, output_height=1024))).convert("RGBA")


def font(sz):
    try:
        return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", sz)
    except Exception:
        return ImageFont.load_default()


icons = {}
for app, lst in PROPOSTE.items():
    for label, fn in lst:
        s = fn()
        key = f"{app} {label[0]}"
        open(f"{OUT}/{key}.svg", "w").write(s)
        im = render(s); im.save(f"{OUT}/{key}.png")
        icons[(app, label)] = im

CW, PAD = 330, 30
rows = []
for bg in [(236, 236, 236), (30, 30, 34)]:
    for app, lst in PROPOSTE.items():
        row = Image.new("RGB", (CW * 3 + PAD, 420), bg)
        d = ImageDraw.Draw(row)
        fg = (20, 20, 20) if bg[0] > 128 else (235, 235, 235)
        d.text((PAD, 14), app, fill=fg, font=font(30))
        for i, (lab, _) in enumerate(lst):
            im = icons[(app, lab)]
            x = PAD + i * CW
            d.text((x, 58), lab, fill=fg, font=font(20))
            big = im.resize((256, 256), Image.LANCZOS); row.paste(big, (x, 92), big)
            xx = x
            for sz in (64, 32, 16):
                sm = im.resize((sz, sz), Image.LANCZOS)
                row.paste(sm, (xx, 360 + (64 - sz) // 2 - 10), sm); xx += sz + 18
        rows.append(row)
board = Image.new("RGB", (rows[0].width, sum(r.height for r in rows)))
y = 0
for r in rows:
    board.paste(r, (0, y)); y += r.height
board.save(f"{OUT}/tavola_confronto_2.png")
print("ok")
