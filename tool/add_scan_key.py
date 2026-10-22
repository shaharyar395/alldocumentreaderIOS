import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "assets" / "l10n"
text = {
    "en": "Scan device storage",
    "ar": "فحص مساحة الجهاز",
    "de": "Gerätespeicher scannen",
    "es": "Escanear almacenamiento del dispositivo",
    "fa": "اسکن حافظه دستگاه",
    "fr": "Analyser le stockage de l'appareil",
    "id": "Pindai penyimpanan perangkat",
    "it": "Scansiona l'archivio del dispositivo",
    "ja": "デバイスのストレージをスキャン",
    "ko": "기기 저장공간 검색",
    "ms": "Imbas storan peranti",
    "pl": "Skanuj pamięć urządzenia",
    "pt": "Verificar o armazenamento do dispositivo",
    "ru": "Сканировать память устройства",
    "th": "สแกนพื้นที่จัดเก็บอุปกรณ์",
    "tl": "I-scan ang storage ng device",
    "tr": "Cihaz depolamasını tara",
    "uk": "Сканувати пам'ять пристрою",
    "ur": "ڈیوائس اسٹوریج اسکین کریں",
    "uz": "Qurilma xotirasini skanerlash",
    "vi": "Quét bộ nhớ thiết bị",
    "zh_Hans": "扫描设备存储",
    "zh_Hant": "掃描裝置儲存空間",
}
for path in sorted(root.glob("*.json")):
    tag = path.stem
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    data["scanStorage"] = text[tag]
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print("updated", tag)
