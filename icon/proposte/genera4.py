"""Dolly finale: bobina rossa scura centrata, 5 finestre, D nel mozzo, fondo nero."""
import io, math, sys, os, importlib.util
OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
sys.argv = [sys.argv[0], OUT + "/_tmp"]
spec = importlib.util.spec_from_file_location("g3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "genera3.py"))
g3 = importlib.util.module_from_spec(spec); spec.loader.exec_module(g3)
from PIL import Image
svg, d_path, render, sector = g3.svg, g3.d_path, g3.render, g3.sector

def dolly():
    cx = cy = 512; R = 330; cut = "#141416"
    defs = '<linearGradient id="red" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#C23038"/><stop offset=".55" stop-color="#8E1820"/><stop offset="1" stop-color="#5A0B11"/></linearGradient>'
    cuts = "".join(f'<path d="{sector(cx, cy, 150, 262, -90 + i*72 + 22, -90 + (i+1)*72 - 22)}" fill="{cut}" stroke="{cut}" stroke-width="36" stroke-linejoin="round"/>' for i in range(5))
    b = f'''<rect width="1024" height="1024" fill="url(#blackbg)"/>
<circle cx="{cx}" cy="{cy}" r="{R}" fill="url(#red)"/>
<circle cx="{cx}" cy="{cy}" r="{R-22}" fill="none" stroke="#3A0408" stroke-width="8" opacity=".5"/>
<circle cx="{cx}" cy="{cy}" r="{R-4}" fill="none" stroke="#FF8A8F" stroke-width="4" opacity=".35"/>
{cuts}
<circle cx="{cx}" cy="{cy}" r="118" fill="url(#red)"/>
<circle cx="{cx}" cy="{cy}" r="100" fill="{cut}"/>
<path d="{d_path(cx-50, cy, 132, 72, 30)}" fill="#F4F2EC"/>
<path d="{d_path(cx-18, cy, 62, 36, 0)}" fill="{cut}"/>'''
    return svg(defs, b)

s = dolly(); open(f"{OUT}/Dolly I.svg", "w").write(s); im = render(s); im.save(f"{OUT}/Dolly I.png")
booth = Image.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "out3", "Booth G.png"))
board = Image.new("RGB", (2 * 300 + 3 * 30 + 2 * (64 + 32 + 16 + 40), 340), (236, 236, 236)); x = 30
for ic in (im, booth):
    big = ic.resize((280, 280), Image.LANCZOS); board.paste(big, (x, 30), big); x += 300
    for sz in (64, 32, 16):
        sm = ic.resize((sz, sz), Image.LANCZOS); board.paste(sm, (x, 140 + (64 - sz) // 2), sm); x += sz + 14
    x += 30
board.save(f"{OUT}/finali.png"); print("ok")
