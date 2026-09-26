"""Riferimento per Siri AI+: la pipeline di app.py (rizzo-pii 2.0.0) sui testi del banco di prova, in JSON.

Uso: python reference.py <repo rizzo-pii> <cartella modello> <uscita.json>
poi: bin/siriai --anonimizza-prova <uscita.json> cpu
"""
import bisect, json, os, re, sys
REPO, MODEL, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(REPO, "src/app"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from detectors import detect_regex, complete_time, SOFT_REGEX_LABELS
from transformers import pipeline, AutoTokenizer
from corpus import TEXTS

MAX_WORDS, OVERLAP = 120, 20
nlp = pipeline("token-classification", model=MODEL, tokenizer=MODEL, aggregation_strategy="simple", device=-1)
tok = AutoTokenizer.from_pretrained(MODEL)

def chunk_text(text, max_words=MAX_WORDS, overlap=OVERLAP):
    words = list(re.finditer(r"\S+", text))
    if not words:
        return []
    chunks, i = [], 0
    step = max(1, max_words - overlap)
    while i < len(words):
        block = words[i:i + max_words]
        start, end = block[0].start(), block[-1].end()
        chunks.append((text[start:end], start))
        if i + max_words >= len(words):
            break
        i += step
    return chunks

def detect_model(text):
    chunks = chunk_text(text)
    ents = []
    if chunks:
        results = nlp([c for c, _ in chunks])
        if isinstance(results, dict):
            results = [results]
        for (_, off), res in zip(chunks, results):
            for e in res:
                ents.append({"label": e["entity_group"], "start": int(e["start"]) + off, "end": int(e["end"]) + off,
                             "score": float(e["score"]), "validated": False, "source": "modello"})
    return ents, len(chunks)

def _is_word(ch):
    return ch.isalnum() or ch == "_"

def _merge(cands, text):
    order = sorted(cands, key=lambda e: (1 if e["validated"] else 0,
                                         1 if (e["source"] == "regex" and e["label"] not in SOFT_REGEX_LABELS) else 0,
                                         e["score"], e["end"] - e["start"]), reverse=True)
    kept = []
    for e in order:
        i = bisect.bisect_right(kept, e["start"], key=lambda k: k["start"])
        if (i and kept[i - 1]["end"] > e["start"]) or (i < len(kept) and kept[i]["start"] < e["end"]):
            continue
        kept.insert(i, e)
    for e in kept:
        while e["start"] < e["end"] and text[e["start"]].isspace():
            e["start"] += 1
        while e["end"] > e["start"] and text[e["end"] - 1].isspace():
            e["end"] -= 1
    kept = [e for e in kept if e["end"] > e["start"]]
    for e in kept:
        while e["start"] > 0 and _is_word(text[e["start"] - 1]) and _is_word(text[e["start"]]):
            e["start"] -= 1
        while e["end"] < len(text) and _is_word(text[e["end"]]) and _is_word(text[e["end"] - 1]):
            e["end"] += 1
    kept.sort(key=lambda e: (e["start"], -(e["end"] - e["start"])))
    merged = []
    for e in kept:
        if merged and e["start"] < merged[-1]["end"]:
            merged[-1]["end"] = max(merged[-1]["end"], e["end"])
            continue
        if merged and e["start"] == merged[-1]["end"] and e["label"] == merged[-1]["label"]:
            merged[-1]["end"] = e["end"]
            continue
        merged.append(e)
    return merged

def _norm(s):
    return re.sub(r"\s+", " ", s.strip()).casefold()

def analyze(text):
    model_ents, n_chunks = detect_model(text)
    complete_time(model_ents, text)
    regex = detect_regex(text)
    kept = _merge([dict(e) for e in model_ents] + [dict(e) for e in regex], text)
    counters, seen, mapping = {}, {}, {}
    anon, pos = [], 0
    for e in kept:
        val = text[e["start"]:e["end"]]
        key = (e["label"], _norm(val))
        if key not in seen:
            counters[e["label"]] = counters.get(e["label"], 0) + 1
            seen[key] = f"[{e['label']}_{counters[e['label']]}]"
            mapping[seen[key]] = val
        e["ph"] = seen[key]
        anon.append(text[pos:e["start"]]); anon.append(e["ph"]); pos = e["end"]
    anon.append(text[pos:])
    return {"text": text, "anonymized": "".join(anon), "mapping": mapping,
            "entities": [{k: e[k] for k in ("label", "start", "end", "source", "validated")} for e in kept],
            "model": [{k: round(e[k], 4) if k == "score" else e[k] for k in ("label", "start", "end", "score")} for e in model_ents],
            "regex": [{k: e[k] for k in ("label", "start", "end", "validated")} for e in regex],
            "chunks": n_chunks}

def tokens(text):
    enc = tok(text, return_offsets_mapping=True)
    return {"text": text, "ids": enc["input_ids"], "offsets": enc["offset_mapping"]}

samples = TEXTS + ["", " ", "  doppio  spazio ", "a\tb\nc", "perché così? È l'età più bella", "東京タワー 🗼 naïve café",
                   "<bos>testo<eos>", " spazio unificato", "C.F. RSSMRA85H12F205Y", "https://www.esempio.it/a?b=1",
                   "\n\n\nrighe\n\n", "ALL CAPS MARIO ROSSI", "x" * 300, "𝒜𝓁𝓅𝒽𝒶 unicode", "ʼapostrofi’ “virgolette”"]
out = {"analyses": [analyze(t) for t in TEXTS], "tokens": [tokens(t) for t in samples]}
json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=1)
print("testi", len(out["analyses"]), "entità", sum(len(a["entities"]) for a in out["analyses"]), "tokenizzazioni", len(out["tokens"]))
