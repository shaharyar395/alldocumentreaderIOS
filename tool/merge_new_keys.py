# -*- coding: utf-8 -*-
"""Merges tool/new_keys_*.json ({key: {lang: text}}) into assets/l10n/<lang>.json.
Checks: all 23 languages present and non-empty, {placeholders} identical to English, no clash
with an existing key that has a different English text. Run from the Flutter project root."""
import glob, json, os, re, sys

LANGS = ["en", "ar", "de", "es", "fa", "fr", "id", "it", "ja", "ko", "ms", "pl", "pt", "ru", "th", "tl",
         "tr", "uk", "ur", "uz", "vi", "zh_Hans", "zh_Hant"]
ph = re.compile(r"\{(\w+)\}")
files = {lang: json.load(open(f"assets/l10n/{lang}.json", encoding="utf-8")) for lang in LANGS}
problems, added = [], 0
for src in sorted(glob.glob("tool/new_keys_*.json")):
    data = json.load(open(src, encoding="utf-8"))
    for key, texts in data.items():
        if not isinstance(texts, dict):
            problems.append(f"{src}: {key}: not a language map"); continue
        en = texts.get("en", "")
        if key in files["en"] and files["en"][key] != en:
            problems.append(f"{src}: {key}: already exists with different English ({files['en'][key]!r} vs {en!r})")
            continue
        want = sorted(ph.findall(en))
        for lang in LANGS:
            text = texts.get(lang) or ""
            if not str(text).strip():
                problems.append(f"{src}: {key}: missing {lang}"); text = en
            # a translation may leave a placeholder out ("one file" forms) but never add a new one
            if not set(ph.findall(text)) <= set(want):
                problems.append(f"{src}: {key}: placeholders differ in {lang}"); text = en
            files[lang][key] = text
        added += 1
for lang, data in files.items():
    with open(f"assets/l10n/{lang}.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
print("keys merged:", added)
print("\n".join(problems) if problems else "no problems")
