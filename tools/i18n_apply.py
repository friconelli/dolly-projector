#!/usr/bin/env python3
"""Una tantum: avvolge i testi visibili in tr()/trf() e genera swift/L10n.swift dalla tabella (tools/i18n_table.py)."""
import re, sys, glob, os
sys.path.insert(0, os.path.dirname(__file__)); from i18n_table import T

def sub(path, pairs):
    t = open(path).read()
    for a, b in pairs:
        assert t.count(a) == 1, (path, a[:80], t.count(a)); t = t.replace(a, b)
    open(path, 'w').write(t)

# 1) letterali con interpolazione -> trf con formato
sub('swift/App.swift', [
 ('showError("Non riesco ad avviare il player: \\(e)")', 'showError(trf("Non riesco ad avviare il player: %@", "\\(e)"))'),
 ('a.informativeText = "Sul telefono (stessa rete del Mac, anche senza internet) inquadra il codice o apri:\\n\\(u)\\n\\nPIN: \\(r.pin)"', 'a.informativeText = trf("Sul telefono (stessa rete del Mac, anche senza internet) inquadra il codice o apri:\\n%@\\n\\nPIN: %@", u, r.pin)'),
])
sub('swift/Engine.swift', [
 ('err = "file mancante: \\(it.title)"', 'err = trf("file mancante: %@", it.title)'),
 ('let msg = "interrotto a \\(Int(pos))s, riprendo"', 'let msg = trf("interrotto a %ds, riprendo", Int(pos))'),
 ('err = "\\(items[idx].title): non riproducibile, passo oltre"', 'err = trf("%@: non riproducibile, passo oltre", items[idx].title)'),
 ('throw DollyError("valore non valido per \\(k)")', 'throw DollyError(trf("valore non valido per %@", k))'),
 ('throw DollyError("proprietà non ammessa: \\(p)")', 'throw DollyError(trf("proprietà non ammessa: %@", p))'),
 ('throw DollyError("colore non valido: \\(val)")', 'throw DollyError(trf("colore non valido: %@", "\\(val)"))'),
 ('throw DollyError("valore non valido: \\(val)")', 'throw DollyError(trf("valore non valido: %@", "\\(val)"))'),
 ('st["err"] = "mpv non risponde: \\(error)"', 'st["err"] = trf("mpv non risponde: %@", "\\(error)")'),
 ('"traccia \\(id)"', 'trf("traccia %d", id)'),
 ('"Capitolo \\(i + 1)"', 'trf("Capitolo %d", i + 1)'),
])
sub('swift/Model.swift', [('"Nero (\\(secs == secs.rounded() ? String(Int(secs)) : String(secs)) s)"', 'trf("Nero (%@ s)", secs == secs.rounded() ? String(Int(secs)) : String(secs))')])
sub('swift/UI.swift', [
 ('Text("player riavviato \\(s.restarts)×")', 'Text(trf("player riavviato %d×", s.restarts))'),
 ('Label("Riprendi \\(s.items[r.idx].label) da \\(fmt(r.pos))"', 'Label(trf("Riprendi %@ da %@", s.items[r.idx].label, fmt(r.pos))'),
 ('return "NERO \\(Int(s.left))″"', 'return trf("NERO %d″", Int(s.left))'),
 ('return "INTERVALLO \\(fmt(s.left))"', 'return trf("INTERVALLO %@", fmt(s.left))'),
 ('"Sostituire la scaletta corrente con “\\(n)”?"', 'trf("Sostituire la scaletta corrente con “%@”?", n)'),
 ('"Eliminare la scena salvata “\\(n)”?"', 'trf("Eliminare la scena salvata “%@”?", n)'),
 ('Text("\\(s.items.count) elementi")', 'Text(trf("%d elementi", s.items.count))'),
 ('"Si ripete \\(it.loop) volte"', 'trf("Si ripete %d volte", it.loop)'),
 ('p.append("nero prima \\(Int(a))″")', 'p.append(trf("nero prima %d″", Int(a)))'),
 ('p.append("nero dopo \\(Int(a))″")', 'p.append(trf("nero dopo %d″", Int(a)))'),
 ('p.append("vol \\(Int(v))%")', 'p.append(trf("vol %d%%", Int(v)))'),
 ('"nero prima di “\\(s.items.indices.contains(s.next) ? s.items[s.next].label : "")”"', 'trf("nero prima di “%@”", s.items.indices.contains(s.next) ? s.items[s.next].label : "")'),
 ('"\\(s.info.res ?? "") · \\(s.info.fps.map { String(format: "%.3f fps", $0) } ?? "")\\n\\(s.info.vcodec ?? "")\\naudio \\(s.info.acodec ?? "")\\nfotogrammi persi: \\(s.info.dropped ?? 0)"',
  'trf("%@ · %@\\n%@\\naudio %@\\nfotogrammi persi: %d", s.info.res ?? "", s.info.fps.map { String(format: "%.3f fps", $0) } ?? "", s.info.vcodec ?? "", s.info.acodec ?? "", s.info.dropped ?? 0)'),
])
sub('swift/Update.swift', [
 ('"Verifica la connessione a internet.\\n(\\(e))"', 'trf("Verifica la connessione a internet.\\n(%@)", "\\(e)")'),
 ('"Hai già l\'ultima versione (\\(Updater.current))."', 'trf("Hai già l\'ultima versione (%@).", Updater.current)'),
 ('a.messageText = "È disponibile la versione \\(i.version)"', 'a.messageText = trf("È disponibile la versione %@", i.version)'),
 ('"Hai la \\(Updater.current). \\(i.notes)\\(i.notes.isEmpty ? "" : "\\n\\n")L\'app viene scaricata (\\(i.bytes / 1_000_000) MB), controllata e riaperta."', 'trf("Hai la %@. %@%@L\'app viene scaricata (%d MB), controllata e riaperta.", Updater.current, i.notes, i.notes.isEmpty ? "" : "\\n\\n", i.bytes / 1_000_000)'),
 ('NSTextField(labelWithString: "Scarico Dolly Projector \\(i.version)…")', 'NSTextField(labelWithString: trf("Scarico Dolly Projector %@…", i.version))'),
 ('throw DollyError("l\'archivio non contiene Dolly Projector \\(i.version)")', 'throw DollyError(trf("l\'archivio non contiene Dolly Projector %@", i.version))'),
])

# 2) letterali semplici -> tr("...") (solo nel codice, non nei commenti, non già avvolti)
def wrap_line(line):
    # tronca il commento: cerca '//' fuori dalle stringhe
    ins, i = False, 0
    cut = len(line)
    while i < len(line):
        c = line[i]
        if c == '\\' and ins: i += 2; continue
        if c == '"': ins = not ins
        elif not ins and line[i:i+2] == '//': cut = i; break
        i += 1
    code, comment = line[:cut], line[cut:]
    for k in sorted((k for k in T if '%' not in k), key=len, reverse=True):
        lit = '"' + k + '"'
        if lit in code:
            code = re.sub(r'(?<!tr\()(?<!trf\()' + re.escape(lit), lambda m, lit=lit: 'tr(' + lit + ')', code)
    return code + comment

for f in glob.glob('swift/*.swift'):
    if os.path.basename(f) in ('L10n.swift', 'RemoteHTML.swift', 'main.swift'): continue
    out = [wrap_line(l) for l in open(f).read().split('\n')]
    open(f, 'w').write('\n'.join(out))

# 3) L10n.swift
def esc(s): return s  # le chiavi sono già nella forma del sorgente (escape inclusi)
rows = ",\n".join(f'    "{k}": "{v}"' for k, v in T.items())
open('swift/L10n.swift', 'w').write(f'''import Foundation

/// Lingua dell\'interfaccia: "auto" (segue il sistema), "it" o "en". DOLLY_LANG serve ai collaudi e agli screenshot.
enum Lang {{
    static var setting: String {{ get {{ ProcessInfo.processInfo.environment["DOLLY_LANG"] ?? UserDefaults.standard.string(forKey: "lang") ?? "auto" }} set {{ UserDefaults.standard.set(newValue, forKey: "lang") }} }}
    static var isEnglish: Bool {{
        switch setting {{
        case "it": return false
        case "en": return true
        default: return !(Locale.preferredLanguages.first ?? "it").hasPrefix("it")   // sistema in italiano -> italiano, altrimenti inglese
        }}
    }}
    static var code: String {{ isEnglish ? "en" : "it" }}
}}

/// Testo dell\'interfaccia: la chiave è l\'italiano, in inglese si cerca la traduzione (se manca resta l\'italiano).
func tr(_ s: String) -> String {{ Lang.isEnglish ? (enStrings[s] ?? s) : s }}
/// Come tr(), per testi con parti variabili (%@ stringhe, %d interi).
func trf(_ s: String, _ args: CVarArg...) -> String {{ String(format: tr(s), arguments: args) }}

let enStrings: [String: String] = [
{rows}
]
''')
print("ok", len(T))
