import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/doc_entry.dart';
import '../../l10n/s.dart';

enum ScanCrop { ask, auto, none }

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  /// In-memory settings for tests and previews.
  AppSettings.defaults() : _prefs = null;

  final SharedPreferences? _prefs;

  ThemeMode themeMode = ThemeMode.system;
  String languageTag = 'en';

  /// "Default" on the Language screen: follow the phone's language ([languageTag] is then the
  /// supported language that matches it).
  bool languageSystem = false;
  bool languageChosen = false;
  bool onboardingDone = false;
  int lastTab = 0;
  bool premium = false;

  /// End of a debug test subscription (ms since epoch), 0 = none. Like the Android app: a test
  /// purchase lasts its plan (30 / 365 days) across restarts, then ads come back.
  int testPremiumUntil = 0;

  bool get testPremiumActive => testPremiumUntil > DateTime.now().millisecondsSinceEpoch;
  ScanCrop scanCrop = ScanCrop.ask;
  bool coachSeen = false;
  bool discoverSeen = false;
  bool horizontalHintSeen = false;
  bool pageTipSeen = false;
  bool mergePromptShown = false;
  bool markupTipSeen = false;

  /// File lists: "Filter by" choice, kept between launches.
  SortField sortField = SortField.date;
  SortDir sortDir = SortDir.desc;

  /// The 5-star "Do you like our app?" sheet was shown (once, after coming back from a file list).
  bool rateShown = false;

  /// A file list (category / Recently added / search) was opened at least once.
  bool visitedFileList = false;

  /// The storage-access prompt was shown once automatically on the home screen.
  bool permissionPrompted = false;

  /// "Do you think … is helpful?": saves since it was last shown, when, and whether it was answered.
  int savesSinceHelpful = 0;
  int helpfulShownAt = 0;
  bool helpfulAnswered = false;

  /// Back presses that started leaving the app (every 3rd may show "Thank you for your support!").
  int exitCount = 0;

  /// When the Recently added list was last opened (ms); the home "+N" counts newer new files.
  int recentSeenAt = 0;

  /// Skips the welcome-back ad after a picker, share sheet, or incoming file.
  bool suppressNextResume = false;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings._(prefs);
    settings.themeMode = _theme(prefs.getString('theme'));
    settings.languageTag = prefs.getString('language') ?? 'en';
    // first start (nothing chosen yet): "Default", the phone's language, like the Android app
    settings.languageSystem = prefs.getBool('languageSystem') ?? !prefs.containsKey('language');
    if (settings.languageSystem) settings.languageTag = systemLanguageTag();
    settings.languageChosen = prefs.getBool('languageChosen') ?? false;
    settings.onboardingDone = prefs.getBool('onboardingDone') ?? false;
    settings.lastTab = prefs.getInt('lastTab') ?? 0;
    settings.premium = prefs.getBool('premium') ?? false;
    settings.testPremiumUntil = prefs.getInt('premium_test_until') ?? 0;
    if (settings.testPremiumUntil > 0 && !settings.testPremiumActive) {
      // the test subscription has run out: Premium off unless a real one was bought
      settings.testPremiumUntil = 0;
      await prefs.remove('premium_test_until');
      if (!(prefs.getBool('premium_store') ?? false)) {
        settings.premium = false;
        await prefs.setBool('premium', false);
      }
    }
    settings.scanCrop = _crop(prefs.getString('scanCrop'));
    settings.coachSeen = prefs.getBool('coachSeen') ?? false;
    settings.discoverSeen = prefs.getBool('discoverSeen') ?? false;
    settings.horizontalHintSeen = prefs.getBool('horizontalHintSeen') ?? false;
    settings.pageTipSeen = prefs.getBool('pageTipSeen') ?? false;
    settings.mergePromptShown = prefs.getBool('mergePromptShown') ?? false;
    settings.markupTipSeen = prefs.getBool('markupTipSeen') ?? false;
    settings.sortField = SortField.values.asNameMap()[prefs.getString('sort_field')] ?? SortField.date;
    settings.sortDir = SortDir.values.asNameMap()[prefs.getString('sort_dir')] ?? SortDir.desc;
    settings.rateShown = prefs.getBool('rate_shown') ?? false;
    settings.visitedFileList = prefs.getBool('visited_file_list') ?? false;
    settings.permissionPrompted = prefs.getBool('permission_prompted') ?? false;
    settings.savesSinceHelpful = prefs.getInt('saves_since_helpful') ?? 0;
    settings.helpfulShownAt = prefs.getInt('helpful_shown_at') ?? 0;
    settings.helpfulAnswered = prefs.getBool('helpful_answered') ?? false;
    settings.exitCount = prefs.getInt('explore_exit_count') ?? 0;
    settings.recentSeenAt = prefs.getInt('recent_seen_at') ?? 0;
    return settings;
  }

  /// The supported app language that matches the phone's language (English if none does).
  static String systemLanguageTag() {
    final tag = localeTag(WidgetsBinding.instance.platformDispatcher.locale);
    return languages.any((lang) => lang.tag == tag) ? tag : 'en';
  }

  /// The phone's language changed while "Default" is chosen.
  void refreshSystemLanguage() {
    if (!languageSystem) return;
    final tag = systemLanguageTag();
    if (tag == languageTag) return;
    languageTag = tag;
    notifyListeners();
  }

  Locale get locale {
    if (languageTag == 'zh_Hans') {
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
    }
    if (languageTag == 'zh_Hant') {
      return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    }
    return Locale(languageTag);
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs?.setString('theme', mode.name);
  }

  /// [system]: "Default" — follow the phone's language ([tag] is ignored then).
  Future<void> setLanguage(String tag, {bool chosen = true, bool system = false}) async {
    languageSystem = system;
    languageTag = system ? systemLanguageTag() : tag;
    languageChosen = chosen;
    notifyListeners();
    await _prefs?.setString('language', languageTag);
    await _prefs?.setBool('languageSystem', system);
    await _prefs?.setBool('languageChosen', chosen);
  }

  Future<void> setSort(SortField field, SortDir dir) async {
    sortField = field;
    sortDir = dir;
    notifyListeners();
    await _prefs?.setString('sort_field', field.name);
    await _prefs?.setString('sort_dir', dir.name);
  }

  Future<void> markRateShown() async {
    rateShown = true;
    await _prefs?.setBool('rate_shown', true);
  }

  Future<void> markVisitedFileList() async {
    if (visitedFileList) return;
    visitedFileList = true;
    await _prefs?.setBool('visited_file_list', true);
  }

  Future<void> markPermissionPrompted() async {
    permissionPrompted = true;
    await _prefs?.setBool('permission_prompted', true);
  }

  /// A file was saved / converted / created (counted for the "is it helpful?" sheet).
  Future<void> noteSaved() async {
    savesSinceHelpful++;
    await _prefs?.setInt('saves_since_helpful', savesSinceHelpful);
  }

  Future<void> markHelpfulShown() async {
    helpfulShownAt = DateTime.now().millisecondsSinceEpoch;
    savesSinceHelpful = 0;
    await _prefs?.setInt('helpful_shown_at', helpfulShownAt);
    await _prefs?.setInt('saves_since_helpful', 0);
  }

  Future<void> markHelpfulAnswered() async {
    helpfulAnswered = true;
    await _prefs?.setBool('helpful_answered', true);
  }

  /// Counts a "leave the app" back press and returns the new count.
  Future<int> countExit() async {
    exitCount++;
    await _prefs?.setInt('explore_exit_count', exitCount);
    return exitCount;
  }

  Future<void> markRecentSeen() async {
    recentSeenAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    await _prefs?.setInt('recent_seen_at', recentSeenAt);
  }

  Future<void> completeOnboarding() async {
    onboardingDone = true;
    notifyListeners();
    await _prefs?.setBool('onboardingDone', true);
  }

  Future<void> setTab(int index) async {
    lastTab = index;
    notifyListeners();
    await _prefs?.setInt('lastTab', index);
  }

  Future<void> setPremium(bool value, {bool fromStore = false}) async {
    if (fromStore || !value) await _prefs?.setBool('premium_store', value);
    if (premium == value) return;
    premium = value;
    notifyListeners();
    await _prefs?.setBool('premium', value);
  }

  /// Debug builds: the test sheet's unlock, for one plan period ([yearly]: 365 days, else 30).
  Future<void> setTestPremium({required bool yearly}) async {
    final days = yearly ? 365 : 30;
    testPremiumUntil = DateTime.now().add(Duration(days: days)).millisecondsSinceEpoch;
    await _prefs?.setInt('premium_test_until', testPremiumUntil);
    await setPremium(true);
  }

  Future<void> setScanCrop(ScanCrop value) async {
    scanCrop = value;
    notifyListeners();
    await _prefs?.setString('scanCrop', value.name);
  }

  Future<void> setFlag(String key, bool value) async {
    if (key == 'coachSeen') {
      coachSeen = value;
    } else if (key == 'discoverSeen') {
      discoverSeen = value;
    } else if (key == 'horizontalHintSeen') {
      horizontalHintSeen = value;
    } else if (key == 'pageTipSeen') {
      pageTipSeen = value;
    } else if (key == 'mergePromptShown') {
      mergePromptShown = value;
    } else if (key == 'markupTipSeen') {
      markupTipSeen = value;
    }
    notifyListeners();
    await _prefs?.setBool(key, value);
  }

  static ThemeMode _theme(String? raw) {
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  static ScanCrop _crop(String? raw) {
    return switch (raw) {
      'auto' => ScanCrop.auto,
      'none' => ScanCrop.none,
      _ => ScanCrop.ask,
    };
  }
}
