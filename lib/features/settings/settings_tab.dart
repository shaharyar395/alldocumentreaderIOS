import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import '../../widgets/explore_sheet.dart';
import '../language/language_page.dart';
import '../premium/premium_page.dart';
import '../search/search_page.dart';
import 'app_links.dart';
import 'faq_page.dart';
import 'feedback_page.dart';
import 'native_bars.dart';
import 'terms_page.dart';
import 'widget_sheet.dart';

/// Play Store page of the app, appended to the Share text (Android Links.shareApp).
const playStoreUrl = 'https://play.google.com/store/apps/details?id=com.theoccess.alldocreader';

/// Settings tab like the Android SettingsFragment: app name + crown + search, the "Remove ads"
/// banner, File manager / FAQ / Share, General (Scan settings, App theme, Language, Feedback or
/// suggestion), Others (Add widget, Explore more apps, Terms of use, Privacy policy, Manage
/// subscriptions) and the version.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  /// The real app version (from the platform), shown at the bottom.
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final version = await PlatformBridge.appVersion();
    if (mounted && version != null && version.isNotEmpty) setState(() => _version = version);
  }

  void _push(Widget page) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final scope = AppScope.of(context);
    final settings = scope.settings;
    // fragment_settings.xml: @color/surface screen
    return Material(
      color: nc.surface,
      child: Column(
        children: [
          // header: app name, crown, search (bg_home_header gradient, 56dp)
          DecoratedBox(
            decoration: NS.bgHomeHeader(context),
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 56,
                padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'All Document Reader',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: nc.textPrimary),
                      ),
                    ),
                    // the crown is for buying Premium: hidden once Premium is on
                    if (!settings.premium)
                      NativeIconButton(
                        icon: ND.icCrown,
                        tooltip: s.t('getPremium'),
                        onTap: () => _push(const PremiumPage()),
                      ),
                    NativeIconButton(
                      icon: ND.icSearch,
                      tint: nc.textPrimary,
                      tooltip: s.t('searchHint'),
                      onTap: () => _push(const SearchPage()),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (!settings.premium) _PremiumBanner(onTap: () => _push(const PremiumPage())),
                _SettingsRow(
                  icon: ND.icStFileManager,
                  title: s.t('fileManager'),
                  onTap: () => openFileManager(context),
                ),
                _SettingsRow(icon: ND.icStFaq, title: s.t('faq'), onTap: () => _push(const FaqPage())),
                _SettingsRow(icon: ND.icShare, title: s.t('share'), onTap: () => shareApp(context)),
                _Section(s.t('general')),
                _SettingsRow(
                  icon: ND.icStScan,
                  title: s.t('scanSettings'),
                  subtitle: _scanLabel(s, settings.scanCrop),
                  onTap: _chooseScan,
                ),
                _SettingsRow(
                  icon: ND.icStTheme,
                  title: s.t('appTheme'),
                  subtitle: _themeLabel(s, settings.themeMode),
                  onTap: _chooseTheme,
                ),
                _SettingsRow(
                  icon: ND.icLanguage,
                  title: s.t('language'),
                  subtitle: _languageName(s, settings),
                  onTap: () => _push(const LanguagePage()),
                ),
                _SettingsRow(
                  icon: ND.icStFeedback,
                  title: s.t('feedbackOrSuggestion'),
                  onTap: () => _push(const FeedbackPage()),
                ),
                _Section(s.t('others')),
                _SettingsRow(icon: ND.icStWidget, title: s.t('addWidget'), onTap: () => showWidgetSheet(context)),
                _SettingsRow(icon: ND.icStMoreApps, title: s.t('exploreMoreApps'), onTap: () => showExploreSheet(context)),
                _SettingsRow(icon: ND.icStTerms, title: s.t('termsOfUse'), onTap: () => _push(const TermsPage())),
                _SettingsRow(
                  icon: ND.icShield,
                  title: s.t('privacyPolicy'),
                  onTap: () {
                    scope.guard.arm(settings);
                    launchUrl(Uri.parse(privacyPolicyUrl), mode: LaunchMode.externalApplication);
                  },
                ),
                _SettingsRow(
                  icon: ND.icStSubscriptions,
                  title: s.t('manageSubscriptions'),
                  subtitle: Platform.isAndroid ? s.t('goToGooglePlay') : null,
                  onTap: () => openManageSubscriptions(context),
                ),
                if (_version != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      s.t('settingsVersion', {'version': _version!}),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: nc.textSecondary, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _scanLabel(S s, ScanCrop crop) => switch (crop) {
        ScanCrop.ask => s.t('askEveryTime'),
        ScanCrop.auto => s.t('autoCrop'),
        ScanCrop.none => s.t('noCrop'),
      };

  static String _themeLabel(S s, ThemeMode mode) => switch (mode) {
        ThemeMode.system => s.t('themeSystemDefault'),
        ThemeMode.light => s.t('light'),
        ThemeMode.dark => s.t('dark'),
      };

  /// The chosen language's name, or "Default" when the app follows the phone.
  static String _languageName(S s, AppSettings settings) {
    if (settings.languageSystem) return s.t('languageDefault');
    for (final lang in languages) {
      if (lang.tag == settings.languageTag) return lang.nativeName;
    }
    return s.t('languageDefault');
  }

  Future<void> _chooseScan() async {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    final modes = ScanCrop.values;
    final picked = await showChoiceSheet(
      context,
      title: s.t('scanSettings'),
      options: [for (final mode in modes) _scanLabel(s, mode)],
      selected: modes.indexOf(settings.scanCrop),
    );
    if (picked == null) return;
    await settings.setScanCrop(modes[picked]);
  }

  Future<void> _chooseTheme() async {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    const modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
    final picked = await showChoiceSheet(
      context,
      title: s.t('appTheme'),
      options: [for (final mode in modes) _themeLabel(s, mode)],
      selected: modes.indexOf(settings.themeMode),
    );
    if (picked == null || modes[picked] == settings.themeMode) return;
    await settings.setTheme(modes[picked]);
  }
}

/// Share: the Android app's share_app_text plus the Play Store link (Android only; there is
/// no App Store id for iOS yet).
Future<void> shareApp(BuildContext context) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  final text = s.t('shareAppText', {'app': 'All Document Reader'});
  scope.guard.arm(scope.settings);
  await Share.share(Platform.isAndroid ? '$text\n$playStoreUrl' : text, subject: s.t('share'));
}

/// Manage subscriptions: the store's subscription page (Google Play / App Store).
Future<void> openManageSubscriptions(BuildContext context) async {
  final scope = AppScope.of(context);
  scope.guard.arm(scope.settings);
  final uri = Platform.isIOS
      ? Uri.parse('https://apps.apple.com/account/subscriptions')
      : Uri.parse('https://play.google.com/store/account/subscriptions?sku=premium_yearly&package=com.theoccess.alldocreader');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// ChoiceSheet of the Android app ("Scan settings" / "App theme"): a title, radio rows (the
/// chosen one highlighted) and OK. Returns the index chosen with OK, or null.
Future<int?> showChoiceSheet(
  BuildContext context, {
  required String title,
  required List<String> options,
  required int selected,
}) {
  return showAppSheet<int>(
    context,
    builder: (_) => _ChoiceSheet(title: title, options: options, selected: selected),
  );
}

class _ChoiceSheet extends StatefulWidget {
  const _ChoiceSheet({required this.title, required this.options, required this.selected});

  final String title;
  final List<String> options;
  final int selected;

  @override
  State<_ChoiceSheet> createState() => _ChoiceSheetState();
}

class _ChoiceSheetState extends State<_ChoiceSheet> {
  late int _choice = widget.selected;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    // sheet_choice.xml
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 20, end: 20, bottom: 10),
            child: Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary)),
          ),
          // item_choice_option.xml: bg_choice_row (choice_selected_bg when selected), choice_text, radio_tint
          for (var i = 0; i < widget.options.length; i++)
            Material(
              color: i == _choice ? nc.choiceSelectedBg : Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _choice = i),
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 20, end: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.options[i],
                            style: TextStyle(fontSize: 16, color: i == _choice ? nc.primary : nc.textPrimary),
                          ),
                        ),
                        NativeRadio(checked: i == _choice),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // btnOk: bg_apply_btn (primary, 24dp corners), 50dp, white 17sp bold
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: NativeApplyButton(label: s.t('ok'), onTap: () => Navigator.pop(context, _choice)),
          ),
        ],
      ),
    );
  }
}

/// "Remove ads" / "Unlock all premium features" banner (bg_premium_banner, ic_banner_clouds).
class _PremiumBanner extends StatelessWidget {
  const _PremiumBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          height: 64,
          decoration: NS.bgPremiumBanner(context),
          child: InkWell(
            onTap: onTap,
            child: Stack(
              children: [
                const PositionedDirectional(
                  end: 30,
                  bottom: 0,
                  child: NativeIcon(ND.icBannerClouds, width: 96, height: 64),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const NativeIcon(ND.icNoAds, size: 20, tint: Colors.white),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    s.t('removeAds'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.t('unlockAllPremium'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      // bg_banner_arrow (white, 12dp corners) 36x24, padding 5dp, ic_chevron_right tint primary
                      Container(
                        width: 36,
                        height: 24,
                        padding: const EdgeInsets.all(5),
                        decoration: NS.bgBannerArrow(context),
                        child: NativeMirror(child: NativeIcon(ND.icChevronRight, tint: nc.primary)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// item_settings_section.xml
class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 18, top: 14, bottom: 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: NC.of(context).toolsSection),
      ),
    );
  }
}

/// item_settings_row.xml: icon, title (+ grey subtitle with the current value), chevron.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.title, required this.onTap, this.subtitle});

  final NDrawable icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final sub = subtitle;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 6, 16, 6),
          child: Row(
            children: [
              NativeIcon(icon, size: 22, tint: nc.textPrimary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
                    if (sub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(sub, style: TextStyle(fontSize: 12, color: nc.textSecondary)),
                      ),
                  ],
                ),
              ),
              NativeMirror(child: NativeIcon(ND.icChevronRight, size: 16, tint: nc.textHint)),
            ],
          ),
        ),
      ),
    );
  }
}
