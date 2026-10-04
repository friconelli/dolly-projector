#!/usr/bin/env python3
"""Genera tre icone macOS Dolly senza dipendenze esterne.

Il rendering avviene in supersampling 4x e il PNG viene scritto direttamente
con la libreria standard, così lo script resta eseguibile anche senza Pillow.
"""
from __future__ import annotations

import math
import struct
import zlib

S = 4
W = H = 1024
N = W * S

BLACK = (0x16, 0x16, 0x16, 255)
GATE = (0xF4, 0xF4, 0xF0, 255)
FILM = (0xD3, 0xD3, 0xCC, 255)
RED = (0xE0, 0x3A, 0x2F, 255)
TRANSPARENT = (0, 0, 0, 0)


def canvas():
    return bytearray(bytes(TRANSPARENT) * (N * N))


def put(buf, x, y, color):
    if 0 <= x < N and 0 <= y < N:
        i = (y * N + x) * 4
        buf[i:i + 4] = bytes(color)


def polygon(buf, points, color):
    pts = [(round(x * S), round(y * S)) for x, y in points]
    min_y = max(0, min(y for _, y in pts)); max_y = min(N - 1, max(y for _, y in pts))
    for y in range(min_y, max_y + 1):
        scan = y + 0.5
        xs = []
        for (x1, y1), (x2, y2) in zip(pts, pts[1:] + pts[:1]):
            if (y1 <= scan < y2) or (y2 <= scan < y1):
                xs.append(x1 + (scan - y1) * (x2 - x1) / (y2 - y1))
        xs.sort()
        for a, b in zip(xs[::2], xs[1::2]):
            left, right = max(0, math.ceil(a)), min(N - 1, math.floor(b))
            for x in range(left, right + 1): put(buf, x, y, color)


def ellipse(buf, box, color, steps=160):
    x0, y0, x1, y1 = box
    pts = [(x0 + (x1-x0)*(1+math.cos(2*math.pi*i/steps))/2,
            y0 + (y1-y0)*(1+math.sin(2*math.pi*i/steps))/2) for i in range(steps)]
    polygon(buf, pts, color)


def rounded_rect(buf, box, r, color):
    x0, y0, x1, y1 = box
    pts = []
    for cx, cy, start in [(x1-r, y0+r, -math.pi/2), (x1-r, y1-r, 0),
                           (x0+r, y1-r, math.pi/2), (x0+r, y0+r, math.pi)]:
        for j in range(25):
            a = start + (math.pi/2) * j/24
            pts.append((cx + r*math.cos(a), cy + r*math.sin(a)))
    polygon(buf, pts, color)


def lanczos(x, a=3):
    if x == 0: return 1.0
    if abs(x) >= a: return 0.0
    p = math.pi * x
    return (math.sin(p) / p) * (math.sin(p / a) / (p / a))


def resize_lanczos(buf, src_w, src_h, dst_w, dst_h):
    """Ridimensionamento RGBA separabile Lanczos-3."""
    tmp = bytearray(dst_w * src_h * 4)
    for y in range(src_h):
        for x in range(dst_w):
            pos = (x + 0.5) * src_w / dst_w - 0.5
            lo, hi = math.floor(pos - 3), math.ceil(pos + 3)
            weights = [(sx, lanczos(pos - sx)) for sx in range(lo, hi + 1) if 0 <= sx < src_w]
            total = sum(w for _, w in weights)
            for c in range(4):
                v = sum(buf[(y*src_w+sx)*4+c] * w for sx, w in weights) / total
                tmp[(y*dst_w+x)*4+c] = max(0, min(255, round(v)))
    out = bytearray(dst_w * dst_h * 4)
    for y in range(dst_h):
        pos = (y + 0.5) * src_h / dst_h - 0.5
        lo, hi = math.floor(pos - 3), math.ceil(pos + 3)
        weights = [(sy, lanczos(pos - sy)) for sy in range(lo, hi + 1) if 0 <= sy < src_h]
        total = sum(w for _, w in weights)
        for x in range(dst_w):
            for c in range(4):
                v = sum(tmp[(sy*dst_w+x)*4+c] * w for sy, w in weights) / total
                out[(y*dst_w+x)*4+c] = max(0, min(255, round(v)))
    return out


def downsample(buf):
    return resize_lanczos(buf, N, N, W, H)


def superellipse(buf, box, exponent, color, steps=720):
    """Tessera macOS: superellisse, non un rounded rectangle."""
    x0, y0, x1, y1 = box
    cx, cy, rx, ry = (x0+x1)/2, (y0+y1)/2, (x1-x0)/2, (y1-y0)/2
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        ca, sa = math.cos(a), math.sin(a)
        pts.append((cx + rx * math.copysign(abs(ca)**(2/exponent), ca),
                    cy + ry * math.copysign(abs(sa)**(2/exponent), sa)))
    polygon(buf, pts, color)


def b2_base():
    b = canvas()
    superellipse(b, (100, 100, 924, 924), 5.0, BLACK)
    return b


def variant_b2():
    b = b2_base()
    # D compatta e centrata: stelo da 130 px e due semicirconferenze concentriche.
    stem_x0, stem_x1 = 315, 445
    cy, outer_r, inner_r = 512, 235, 105
    polygon(b, [(stem_x0, cy-outer_r), (stem_x1, cy-outer_r),
                (stem_x1, cy+outer_r), (stem_x0, cy+outer_r)], GATE)
    outer = [(stem_x1, cy-outer_r)]
    for i in range(181):
        a = -math.pi/2 + math.pi*i/180
        outer.append((stem_x1 + outer_r*math.cos(a), cy + outer_r*math.sin(a)))
    polygon(b, outer, GATE)
    inner = [(stem_x1, cy-inner_r)]
    for i in range(181):
        a = -math.pi/2 + math.pi*i/180
        inner.append((stem_x1 + inner_r*math.cos(a), cy + inner_r*math.sin(a)))
    polygon(b, inner, BLACK)
    # Cue mark ad anello, separato dalla D e con margine dalla tessera.
    ellipse(b, (725, 190, 845, 310), RED)
    ellipse(b, (751, 216, 819, 284), BLACK)
    return b


def preview_b2(full):
    sizes = [256, 128, 64, 32]
    pad, gap = 24, 24
    width, height = sum(sizes) + gap * (len(sizes)-1) + pad*2, 256 + pad*2
    out = bytearray(bytes((0xE4, 0xE4, 0xE4, 255)) * (width * height))
    x = pad
    for size in sizes:
        small = resize_lanczos(full, N, N, size, size)
        y = pad + (256-size)//2
        for yy in range(size):
            for xx in range(size):
                si = (yy*size+xx)*4
                di = ((y+yy)*width+x+xx)*4
                a = small[si+3] / 255.0
                for c in range(3):
                    out[di+c] = round(small[si+c]*a + 0xE4*(1-a))
                out[di+3] = 255
        x += size + gap
    write_png('anteprima_piccole.png', out, width, height)


def write_png(path, rgba, width=W, height=H):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\0' + bytes(rgba[y*width*4:(y+1)*width*4]) for y in range(height))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f: f.write(png)


def base():
    b = canvas()
    rounded_rect(b, (100, 100, 924, 924), 185, BLACK)
    return b


def variant_a():
    b = base()
    # Un rettangolo-gate 16:9, con una cornice pellicola appena percepibile.
    rounded_rect(b, (176, 287, 848, 737), 20, FILM)
    rounded_rect(b, (196, 307, 828, 717), 8, GATE)
    # Il cue mark è piccolo ma netto e vive dentro l'angolo del fotogramma.
    ellipse(b, (744, 326, 798, 380), RED)
    return b


def variant_b():
    b = base()
    # D costruita come silhouette geometrica: montante + curva esterna.
    outer = [(236, 214), (367, 214)]
    for i in range(41):
        a = -math.pi/2 + math.pi*i/40
        outer.append((367 + 370*math.cos(a), 502 + 288*math.sin(a)))
    outer += [(236, 790)]
    polygon(b, outer, GATE)
    # Scavo interno, mantiene la forma di D anche alle dimensioni minime.
    inner = [(367, 342)]
    for i in range(41):
        a = -math.pi/2 + math.pi*i/40
        inner.append((367 + 210*math.cos(a), 502 + 160*math.sin(a)))
    inner += [(367, 662)]
    polygon(b, inner, BLACK)
    # Il foro della D diventa il punto di cambio bobina.
    ellipse(b, (533, 468, 613, 548), RED)
    return b


def variant_c():
    b = base()
    # Simbolo di regia: gate centrale spesso, cue sul bordo e linea di segnale.
    rounded_rect(b, (218, 262, 806, 742), 54, GATE)
    rounded_rect(b, (282, 326, 742, 678), 20, BLACK)
    # Apertura orizzontale: richiama il fotogramma, non un play button.
    rounded_rect(b, (282, 438, 742, 566), 28, FILM)
    rounded_rect(b, (326, 462, 698, 542), 18, BLACK)
    # Interruzione del bordo in alto a destra, occupata dal cue mark.
    rounded_rect(b, (670, 230, 850, 368), 60, BLACK)
    ellipse(b, (700, 262, 788, 350), RED)
    return b


if __name__ == '__main__':
    write_png('variante_a.png', downsample(variant_a()))
    write_png('variante_b.png', downsample(variant_b()))
    write_png('variante_c.png', downsample(variant_c()))
    b2_hi = variant_b2()
    b2 = downsample(b2_hi)
    write_png('variante_b2.png', b2)
    preview_b2(b2_hi)
    print('Create variante_a.png, variante_b.png, variante_c.png, variante_b2.png, anteprima_piccole.png')
