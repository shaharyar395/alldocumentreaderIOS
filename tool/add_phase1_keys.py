# -*- coding: utf-8 -*-
"""Phase 1 keys. Texts that exist in the Android app take its translations (values-*/strings.xml);
"splitEveryPage" is new. Run from the Flutter project root:
    python tool/add_phase1_keys.py [path-to-android-res]"""
import json, os, re, sys

ANDROID_RES = sys.argv[1] if len(sys.argv) > 1 else ""
# Flutter JSON name -> Android values folder
LOCALES = {"en": "values", "ar": "values-ar", "de": "values-de", "es": "values-es", "fa": "values-fa", "fr": "values-fr",
           "id": "values-in", "it": "values-it", "ja": "values-ja", "ko": "values-ko", "ms": "values-ms", "pl": "values-pl",
           "pt": "values-pt", "ru": "values-ru", "th": "values-th", "tl": "values-tl", "tr": "values-tr", "uk": "values-uk",
           "ur": "values-ur", "uz": "values-uz", "vi": "values-vi", "zh_Hans": "values-zh-rCN", "zh_Hant": "values-zh-rTW"}
FROM_ANDROID = {"pressBackAgain": "press_back_again", "saveFailed": "save_failed",
                "splitFixedRange": "split_fixed_range", "splitCustomRange": "split_custom_range"}
EVERY_PAGE = {"en": "Every page", "ar": "كل صفحة", "de": "Jede Seite", "es": "Cada página", "fa": "هر صفحه",
              "fr": "Chaque page", "id": "Setiap halaman", "it": "Ogni pagina", "ja": "各ページ", "ko": "모든 페이지",
              "ms": "Setiap halaman", "pl": "Każda strona", "pt": "Cada página", "ru": "Каждая страница",
              "th": "ทุกหน้า", "tl": "Bawat pahina", "tr": "Her sayfa", "uk": "Кожна сторінка", "ur": "ہر صفحہ",
              "uz": "Har bir sahifa", "vi": "Mỗi trang", "zh_Hans": "每一页", "zh_Hant": "每一頁"}
# copied from the Android app (so the tool also runs without its res folder)
FALLBACK = json.load(open(os.path.join(os.path.dirname(__file__), "phase1_android_texts.json"), encoding="utf-8"))

def android_text(folder, key):
    if not ANDROID_RES:
        return None
    path = os.path.join(ANDROID_RES, folder, "strings.xml")
    if not os.path.exists(path):
        return None
    m = re.search(r'<string name="%s"[^>]*>(.*?)</string>' % key, open(path, encoding="utf-8").read(), re.S)
    if not m:
        return None
    t = m.group(1)
    return t.replace("\\'", "'").replace('\\"', '"').replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")

for name, folder in LOCALES.items():
    path = os.path.join("assets", "l10n", name + ".json")
    data = json.load(open(path, encoding="utf-8"))
    for key, akey in FROM_ANDROID.items():
        data[key] = android_text(folder, akey) or FALLBACK[name][key]
    data["splitEveryPage"] = EVERY_PAGE[name]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
print("phase 1 keys added to", len(LOCALES), "languages")
