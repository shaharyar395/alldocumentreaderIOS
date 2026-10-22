import json
from pathlib import Path

root = Path("assets/l10n")
en = json.loads((root / "en.json").read_text(encoding="utf-8"))
keys = list(en)

def write(tag, values):
    if len(values) != len(keys):
        raise SystemExit(f"{tag}: {len(values)} != {len(keys)}")
    data = dict(zip(keys, values))
    for key, value in data.items():
        for token in ("{percent}", "{days}", "{count}", "{current}", "{total}", "{used}"):
            if token in en[key] and token not in value:
                raise SystemExit(f"{tag}.{key} missing {token}")
    path = root / f"{tag}.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("wrote", tag)

tags = [
    "de", "es", "fr", "it", "pt", "pl", "ru", "uk", "tr",
    "ar", "fa", "ur", "id", "ms", "ja", "ko", "th", "vi",
    "tl", "uz", "zh_Hans", "zh_Hant",
]
tool = Path("tool")
for tag in tags:
    lines = (tool / f"{tag}.txt").read_text(encoding="utf-8").splitlines()
    write(tag, lines)
