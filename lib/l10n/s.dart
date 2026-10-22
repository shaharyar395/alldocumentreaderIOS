import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class LangOption {
  const LangOption(this.tag, this.nativeName, this.locale);
  final String tag;
  final String nativeName;
  final Locale locale;
}

/// The app languages in the order and with the names of the Android app's Language screen
/// (data/Languages.kt); "Default" (the phone's language) comes before them.
const languages = <LangOption>[
  LangOption('en', 'English', Locale('en')),
  LangOption('ar', 'العربية', Locale('ar')),
  LangOption('de', 'Deutsch', Locale('de')),
  LangOption('es', 'Español', Locale('es')),
  LangOption('fa', 'فارسی', Locale('fa')),
  LangOption('fr', 'Français', Locale('fr')),
  LangOption('id', 'Indonesia', Locale('id')),
  LangOption('it', 'Italiano', Locale('it')),
  LangOption('ja', '日本語', Locale('ja')),
  LangOption('ko', '한국어', Locale('ko')),
  LangOption('ms', 'Melayu', Locale('ms')),
  LangOption('pt', 'Português', Locale('pt')),
  LangOption('ru', 'Русский', Locale('ru')),
  LangOption('tr', 'Türkçe', Locale('tr')),
  LangOption('vi', 'Tiếng Việt', Locale('vi')),
  LangOption('uz', "O'zbekcha", Locale('uz')),
  LangOption('th', 'ภาษาไทย', Locale('th')),
  LangOption('uk', 'Українська', Locale('uk')),
  LangOption('pl', 'Polski', Locale('pl')),
  LangOption('tl', 'Filipino', Locale('tl')),
  LangOption('zh_Hant', '繁體中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),
  LangOption('ur', 'اردو', Locale('ur')),
  LangOption('zh_Hans', '简体中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')),
];

String localeTag(Locale locale) {
  if (locale.languageCode == 'zh') {
    final script = locale.scriptCode;
    if (script == 'Hant' || locale.countryCode == 'TW' || locale.countryCode == 'HK') {
      return 'zh_Hant';
    }
    return 'zh_Hans';
  }
  return locale.languageCode;
}

class S {
  S(this.tag, this._values, this._english);

  final String tag;
  final Map<String, String> _values;
  final Map<String, String> _english;

  static Map<String, Map<String, String>> _cache = {};

  static Future<void> preload() async {
    if (_cache.isNotEmpty) return;
    final next = <String, Map<String, String>>{};
    for (final lang in languages) {
      final raw = await rootBundle.loadString('assets/l10n/${lang.tag}.json');
      next[lang.tag] = Map<String, String>.from(json.decode(raw) as Map);
    }
    _cache = next;
  }

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S) ?? S('en', _cache['en'] ?? {}, _cache['en'] ?? {});
  }

  String t(String key, [Map<String, String> args = const {}]) {
    var value = _values[key] ?? _english[key] ?? key;
    for (final entry in args.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value);
    }
    return value;
  }
}

class SDelegate extends LocalizationsDelegate<S> {
  const SDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<S> load(Locale locale) async {
    await S.preload();
    final tag = localeTag(locale);
    final english = S._cache['en'] ?? {};
    return S(tag, S._cache[tag] ?? english, english);
  }

  @override
  bool shouldReload(covariant SDelegate old) => false;
}
