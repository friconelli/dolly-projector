"""Proposte icone Dolly Projector e Booth: SVG vettoriali -> PNG 1024 + tavola di confronto."""
import io, math, sys, os
import cairosvg
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def squircle(x0=100, y0=100, size=824, n=5.0, steps=360):
    cx = cy = None
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
<linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
{defs}</defs>
<path d="M{TILE[1:]}" fill="#000" opacity=".22" transform="translate(0,10)"/>
<g clip-path="url(#tile)">{body}<rect width="1024" height="1024" fill="url(#gloss)"/></g>
<path d="{TILE}" fill="none" stroke="#000" stroke-opacity=".18" stroke-width="2"/>
</svg>'''


def reel_holes(cx, cy, rad, r, n=6, fill="#000"):
    out = []
    for i in range(n):
        a = -math.pi / 2 + 2 * math.pi * i / n
        out.append(f'<circle cx="{cx + rad*math.cos(a):.1f}" cy="{cy + rad*math.sin(a):.1f}" r="{r}" fill="{fill}"/>')
    return "".join(out)


# ---------------- DOLLY ----------------
def dolly_fascio():
    d = '''<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1B2A55"/><stop offset="1" stop-color="#0A1028"/></linearGradient>
<linearGradient id="beam" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FFF6DA" stop-opacity="1"/><stop offset=".5" stop-color="#FFD873" stop-opacity=".55"/><stop offset="1" stop-color="#FFC94A" stop-opacity=".08"/></linearGradient>
<radialGradient id="dust" cx="0" cy=".5" r="1"><stop offset="0" stop-color="#fff" stop-opacity=".5"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<radialGradient id="glass" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#E9F6FF"/><stop offset=".35" stop-color="#7FC0F0"/><stop offset="1" stop-color="#1D4E8C"/></radialGradient>
<linearGradient id="metal" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E8E8EC"/><stop offset="1" stop-color="#8A8E99"/></linearGradient>'''
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<polygon points="330,440 930,250 930,774 330,584" fill="url(#beam)"/>
<polygon points="330,470 930,400 930,624 330,554" fill="url(#dust)"/>
<circle cx="300" cy="512" r="150" fill="url(#metal)"/>
<circle cx="300" cy="512" r="118" fill="#20242E"/>
<circle cx="300" cy="512" r="96" fill="url(#glass)"/>
<ellipse cx="268" cy="474" rx="34" ry="22" fill="#fff" opacity=".75"/>
<circle cx="300" cy="512" r="150" fill="none" stroke="#5A5F6B" stroke-width="6"/>'''
    return svg(d, b)


def dolly_bobina():
    d = '''<radialGradient id="bg" cx=".5" cy=".35" r=".85"><stop offset="0" stop-color="#B3262A"/><stop offset="1" stop-color="#4C0A0E"/></radialGradient>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE29A"/><stop offset=".55" stop-color="#E3A93C"/><stop offset="1" stop-color="#A86A1C"/></linearGradient>'''
    holes = reel_holes(512, 470, 160, 66, 6, "#5E0D12")
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M512,770 C600,770 640,700 760,700 L1024,700 L1024,800 L760,800 C660,800 620,870 512,870 Z" fill="#1A0507" opacity=".9"/>
<g fill="#E3A93C" opacity=".9">{"".join(f'<rect x="{x}" y="720" width="34" height="22" rx="5"/><rect x="{x}" y="760" width="34" height="22" rx="5"/>' for x in (800, 870, 940))}</g>
<circle cx="512" cy="470" r="300" fill="url(#gold)"/>
<circle cx="512" cy="470" r="300" fill="none" stroke="#7A4A10" stroke-width="10" opacity=".55"/>
<circle cx="512" cy="470" r="262" fill="none" stroke="#FFF2C4" stroke-width="6" opacity=".55"/>
{holes}
<circle cx="512" cy="470" r="58" fill="#5E0D12"/>
<circle cx="512" cy="470" r="24" fill="url(#gold)"/>'''
    return svg(d, b)


def dolly_sipario():
    d = '''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#17171B"/><stop offset="1" stop-color="#050506"/></linearGradient>
<radialGradient id="scr" cx=".5" cy=".45" r=".7"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#D9E6F5"/></radialGradient>
<radialGradient id="glow" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#BFD8FF" stop-opacity=".55"/><stop offset="1" stop-color="#BFD8FF" stop-opacity="0"/></radialGradient>
<linearGradient id="fold" x1="0" y1="0" x2="1" y2="0" spreadMethod="repeat"><stop offset="0" stop-color="#7E0E14"/><stop offset=".5" stop-color="#D3313A"/><stop offset="1" stop-color="#7E0E14"/></linearGradient>
<pattern id="folds" width="70" height="1024" patternUnits="userSpaceOnUse"><rect width="70" height="1024" fill="url(#fold)"/></pattern>'''
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<ellipse cx="512" cy="520" rx="330" ry="260" fill="url(#glow)"/>
<rect x="262" y="350" width="500" height="320" rx="14" fill="url(#scr)"/>
<polygon points="472,440 472,580 590,510" fill="#C8202A"/>
<path d="M0,0 L380,0 C350,250 300,420 230,1024 L0,1024 Z" fill="url(#folds)"/>
<path d="M1024,0 L644,0 C674,250 724,420 794,1024 L1024,1024 Z" fill="url(#folds)"/>
<path d="M0,0 L1024,0 L1024,190 C860,240 700,170 512,215 C324,170 164,240 0,190 Z" fill="url(#folds)"/>
<path d="M0,190 C164,240 324,170 512,215 C700,170 860,240 1024,190" fill="none" stroke="#F2C14E" stroke-width="12"/>'''
    return svg(d, b)


# ---------------- BOOTH ----------------
def perfs(x0, x1, y, w=34, h=26, step=62, fill="#F3EEE3"):
    return "".join(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}"/>' for x in range(x0, x1, step))


def booth_spunta():
    d = '''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FBF7EE"/><stop offset="1" stop-color="#E9E1CF"/></linearGradient>
<linearGradient id="img" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#7DB7E8"/><stop offset=".62" stop-color="#F6C98A"/><stop offset=".62" stop-color="#3E5B4A"/><stop offset="1" stop-color="#2A3F33"/></linearGradient>
<linearGradient id="ok" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3CCB7F"/><stop offset="1" stop-color="#1E9A57"/></linearGradient>'''
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<rect x="150" y="250" width="640" height="470" rx="26" fill="#1E1E22"/>
{perfs(185, 760, 272)}{perfs(185, 760, 672)}
<rect x="190" y="320" width="560" height="330" rx="10" fill="url(#img)"/>
<circle cx="640" cy="390" r="34" fill="#FFF3D0"/>
<circle cx="745" cy="705" r="150" fill="#FBF7EE"/>
<circle cx="745" cy="705" r="128" fill="url(#ok)"/>
<polyline points="682,708 728,754 812,662" fill="none" stroke="#fff" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/>'''
    return svg(d, b)


def booth_lente():
    d = '''<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#17A3A0"/><stop offset="1" stop-color="#0B4F5C"/></linearGradient>
<radialGradient id="lens" cx=".4" cy=".35" r=".75"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".45"/><stop offset="1" stop-color="#BFF5F0" stop-opacity=".12"/></radialGradient>'''
    strip = f'''<g transform="rotate(-18 512 512)">
<rect x="-100" y="400" width="1224" height="230" fill="#15181C"/>
{perfs(-80, 1120, 418, 40, 30, 74, "#0F7F80")}{perfs(-80, 1120, 582, 40, 30, 74, "#0F7F80")}
{"".join(f'<rect x="{x}" y="462" width="150" height="106" rx="6" fill="#2D3640"/>' for x in range(-60, 1120, 180))}
</g>'''
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
{strip}
<g transform="rotate(-45 450 450)"><rect x="395" y="655" width="110" height="250" rx="55" fill="#1B2630"/><rect x="415" y="655" width="22" height="230" rx="11" fill="#fff" opacity=".18"/></g>
<circle cx="450" cy="450" r="215" fill="url(#lens)"/>
<circle cx="450" cy="450" r="215" fill="none" stroke="#FFFFFF" stroke-width="46"/>
<polyline points="360,455 425,520 545,390" fill="none" stroke="#FFD34D" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>'''
    return svg(d, b)


def booth_onda():
    d = '''<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF9A45"/><stop offset="1" stop-color="#E2492A"/></linearGradient>'''
    import random
    random.seed(7)
    bars = []
    x = 250
    while x < 780:
        t = (x - 250) / 530
        h = 30 + 170 * abs(math.sin(t * 9.0)) * (0.55 + 0.45 * random.random())
        bars.append(f'<rect x="{x}" y="{512-h/2:.0f}" width="18" height="{h:.0f}" rx="9" fill="#2A1B3D"/>')
        x += 30
    b = f'''<rect width="1024" height="1024" fill="url(#bg)"/>
<rect x="190" y="250" width="644" height="524" rx="64" fill="#FFF6EC"/>
{"".join(bars)}
<rect x="590" y="300" width="14" height="424" rx="7" fill="#E2492A"/>
<polygon points="572,286 622,286 597,322" fill="#E2492A"/>'''
    return svg(d, b)


PROPOSTE = {
    "Dolly": [("A - Fascio di luce", dolly_fascio), ("B - Bobina", dolly_bobina), ("C - Sipario", dolly_sipario)],
    "Booth": [("A - Fotogramma ok", booth_spunta), ("B - Lente", booth_lente), ("C - Onda audio", booth_onda)],
}
ATTUALI = {"Dolly": sys.argv[2], "Booth": sys.argv[3]}


def render(s):
    return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=s.encode(), output_width=1024, output_height=1024))).convert("RGBA")


def font(sz):
    for f in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(f, sz)
        except Exception:
            pass
    return ImageFont.load_default()


icons = {}
for app, lst in PROPOSTE.items():
    for label, fn in lst:
        s = fn()
        key = f"{app} {label[0]}"
        open(f"{OUT}/{key}.svg", "w").write(s)
        im = render(s)
        im.save(f"{OUT}/{key}.png")
        icons[(app, label)] = im

# tavola: per app, colonna "attuale" + 3 proposte; ogni cella 256 + 64 + 32 + 16
CW, PAD = 330, 30
rows = []
for bg in [(236, 236, 236), (30, 30, 34)]:
    for app, lst in PROPOSTE.items():
        cells = [("Attuale", Image.open(ATTUALI[app]).convert("RGBA"))] + [(l, icons[(app, l)]) for l, _ in lst]
        row = Image.new("RGB", (CW * 4 + PAD, 420), bg)
        d = ImageDraw.Draw(row)
        fg = (20, 20, 20) if bg[0] > 128 else (235, 235, 235)
        d.text((PAD, 14), app, fill=fg, font=font(30))
        for i, (lab, im) in enumerate(cells):
            x = PAD + i * CW
            d.text((x, 58), lab, fill=fg, font=font(20))
            big = im.resize((256, 256), Image.LANCZOS)
            row.paste(big, (x, 92), big)
            xx = x
            for sz in (64, 32, 16):
                sm = im.resize((sz, sz), Image.LANCZOS)
                row.paste(sm, (xx, 360 + (64 - sz) // 2 - 10), sm)
                xx += sz + 18
        rows.append(row)
board = Image.new("RGB", (rows[0].width, sum(r.height for r in rows)))
y = 0
for r in rows:
    board.paste(r, (0, y)); y += r.height
board.save(f"{OUT}/tavola_confronto.png")
print("ok", OUT)
