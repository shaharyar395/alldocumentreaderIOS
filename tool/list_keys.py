import re
import pathlib

keys = set()
for path in pathlib.Path("lib").rglob("*.dart"):
    text = path.read_text(encoding="utf-8")
    keys.update(re.findall(r"\.t\('([A-Za-z0-9]+)'", text))
print("\n".join(sorted(keys)))
print("COUNT", len(keys))
