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
import '../../services/app_analytics.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // iOS home-screen widgets: their texts in the app's language (this tab is built at start
    // and again whenever the language changes)
    if (Platform.isIOS) PlatformBridge.updateWidgetLabels(widgetLabels(S.of(context)));
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
    void tap(String item, VoidCallback action) {
      logEvent('settings_tap', {'item': item});
      logEvent(_settingsEvent(item));
      action();
    }

    // fragment_settings.xml ("Plum deck" 1.0.35+): "Settings" with crown and search, the stacked
    // "Remove ads" card, then label + white rounded card groups of rows, and the version
    final groups = <(String?, List<Widget>)>[
      (
        null,
        [
          _SettingsRow(
            icon: ND.icStFileManager,
            title: s.t('fileManager'),
            onTap: () => tap('file_manager', () => openFileManager(context)),
          ),
          _SettingsRow(icon: ND.icStFaq, title: s.t('faq'), onTap: () => tap('faq', () => _push(const FaqPage()))),
          Builder(
            builder: (rowContext) => _SettingsRow(
              icon: ND.icShare,
              title: s.t('share'),
              onTap: () => tap('share', () => shareApp(rowContext)),
            ),
          ),
        ],
      ),
      (
        s.t('general'),
        [
          _SettingsRow(
            icon: ND.icStScan,
            title: s.t('scanSettings'),
            subtitle: _scanLabel(s, settings.scanCrop),
            onTap: () => tap('scan_settings', _chooseScan),
          ),
          _SettingsRow(
            icon: ND.icStTheme,
            title: s.t('appTheme'),
            subtitle: _themeLabel(s, settings.themeMode),
            onTap: () => tap('app_theme', _chooseTheme),
          ),
          _SettingsRow(
            icon: ND.icLanguage,
            title: s.t('language'),
            subtitle: _languageName(s, settings),
            onTap: () => tap('language', () => _push(const LanguagePage())),
          ),
          _SettingsRow(
            icon: ND.icStFeedback,
            title: s.t('feedbackOrSuggestion'),
            onTap: () => tap('feedback_or_suggestion', () => _push(const FeedbackPage())),
          ),
        ],
      ),
      (
        s.t('others'),
        [
          _SettingsRow(icon: ND.icStWidget, title: s.t('addWidget'), onTap: () => tap('add_widget', () => showWidgetSheet(context))),
          _SettingsRow(
            icon: ND.icStMoreApps,
            title: s.t('exploreMoreApps'),
            onTap: () => tap('explore_more_apps', () => showExploreSheet(context)),
          ),
          _SettingsRow(icon: ND.icStTerms, title: s.t('termsOfUse'), onTap: () => tap('terms_of_use', () => _push(const TermsPage()))),
          _SettingsRow(
            icon: ND.icShield,
            title: s.t('privacyPolicy'),
            onTap: () => tap('privacy_policy', () {
              scope.guard.arm(settings);
              launchUrl(Uri.parse(privacyPolicyUrl), mode: LaunchMode.externalApplication);
            }),
          ),
          _SettingsRow(
            icon: ND.icStSubscriptions,
            title: s.t('manageSubscriptions'),
            subtitle: Platform.isAndroid ? s.t('goToGooglePlay') : (Platform.isIOS ? s.t('goToAppStore') : null),
            onTap: () => tap('manage_subscriptions', () => openManageSubscriptions(context)),
          ),
        ],
      ),
    ];
    var order = 0;
    return Material(
      color: nc.bgScreen,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 20, end: 10),
                child: Row(
                  children: [
                    Expanded(child: Text(s.t('settings'), maxLines: 1, overflow: TextOverflow.ellipsis, style: dsScreenTitle(context))),
                    // the crown is for buying Premium: hidden once Premium is on
                    if (!settings.premium)
                      DsCircleButton(
                        fill: nc.accentContainer,
                        icon: ND.icCrown,
                        iconPadding: 13,
                        tooltip: s.t('getPremium'),
                        onTap: () {
                          logEvent('settings_premium_tapped');
                          _push(const PremiumPage());
                        },
                      ),
                    DsTopAction(
                      icon: ND.icSearch,
                      tooltip: s.t('searchHint'),
                      onTap: () {
                        logEvent('settings_search_tapped');
                        _push(const SearchPage());
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, kNavBarClearance + 8),
                children: [
                  if (!settings.premium)
                    _Rise(
                      order: order++,
                      child: _PremiumBanner(
                        onTap: () {
                          logEvent('settings_remove_ads_tapped');
                          _push(const PremiumPage());
                        },
                      ),
                    ),
                  for (final (title, rows) in groups)
                    _Rise(
                      order: order++,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (title != null) _Section(title),
                          _Card(rows: rows),
                        ],
                      ),
                    ),
                  if (_version != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
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
    logEvent(const ['settings_scan_ask_every_time', 'settings_scan_auto_crop', 'settings_scan_no_crop'][picked]);
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
    if (picked == null) return;
    logEvent(const ['settings_theme_system', 'settings_theme_light', 'settings_theme_dark'][picked]);
    if (modes[picked] == settings.themeMode) return;
    await settings.setTheme(modes[picked]);
  }
}

/// Share: the Android app's share_app_text plus the store link (Play Store on Android; on iOS the
/// App Store page once [appStoreId] is set). [context] is the tapped row (iPad popover anchor).
Future<void> shareApp(BuildContext context) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  final text = s.t('shareAppText', {'app': 'All Document Reader'});
  final String message;
  if (Platform.isAndroid) {
    message = '$text\n$playStoreUrl';
  } else if (Platform.isIOS && appStoreId.isNotEmpty) {
    message = '$text\n$appStoreUrl';
  } else {
    message = text;
  }
  final origin = shareOrigin(context);
  scope.guard.arm(scope.settings);
  await Share.share(message, subject: s.t('share'), sharePositionOrigin: origin);
}

/// Manage subscriptions: the store's subscription page (Google Play; on iOS the App Store's own
/// "Manage subscriptions" sheet, the web page only when the sheet can't be shown).
Future<void> openManageSubscriptions(BuildContext context) async {
  final scope = AppScope.of(context);
  if (Platform.isIOS && await PlatformBridge.manageSubscriptions()) return;
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
    // sheet_choice.xml ("Plum deck"): handle, 18 sp medium title, rounded option cards (the chosen
    // one accent_container with a primary outline), then the OK pill
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHandle(),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 20, 12),
            child: Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: nc.textPrimary)),
          ),
          for (var i = 0; i < widget.options.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Material(
                color: i == _choice ? nc.accentContainer : nc.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: i == _choice ? nc.primary : nc.divider, width: i == _choice ? 1.5 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() => _choice = i),
                  splashColor: nc.rowPressed,
                  child: SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(start: 16, end: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.options[i],
                              style: TextStyle(fontSize: 15, color: i == _choice ? nc.primary : nc.textPrimary),
                            ),
                          ),
                          NativeRadio(checked: i == _choice),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: NativeApplyButton(label: s.t('ok'), height: 48, onTap: () => Navigator.pop(context, _choice)),
          ),
        ],
      ),
    );
  }
}

/// The "Remove ads · Unlock all premium features" card (bannerPremium): an accent_soft card (74 dp,
/// 18 dp corners, 14 dp in) peeking out under the front card (76 dp, deck_front → deck_track
/// gradient): a 40 dp ring with ic_no_ads, the two lines and a 34 dp accent_soft arrow.
class _PremiumBanner extends StatelessWidget {
  const _PremiumBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: SizedBox(
        height: 86,
        child: Stack(
          children: [
            Positioned(
              left: 14,
              right: 14,
              bottom: 0,
              height: 74,
              child: DecoratedBox(decoration: BoxDecoration(color: nc.accentSoft, borderRadius: BorderRadius.circular(18))),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 76,
              child: Semantics(
                button: true,
                label: '${s.t('removeAds')}, ${s.t('unlockAllPremium')}',
                excludeSemantics: true,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                  clipBehavior: Clip.antiAlias,
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
                        end: rtl ? Alignment.centerLeft : Alignment.centerRight,
                        colors: [nc.deckFront, nc.deckTrack],
                      ),
                    ),
                    child: InkWell(
                      onTap: onTap,
                      splashColor: const Color(0x33FFFFFF),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 16, end: 14),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0x1FFFFFFF),
                                shape: BoxShape.circle,
                                border: Border.all(color: nc.accentSoft, width: 1.5),
                              ),
                              child: NativeIcon(ND.icNoAds, size: 22, tint: nc.accentSoft),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.t('removeAds'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                                  ),
                                  Text(
                                    s.t('unlockAllPremium'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: nc.deckTextSoft, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 34,
                              height: 34,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: nc.accentSoft, shape: BoxShape.circle),
                              child: NativeMirror(child: NativeIcon(ND.icChevronRight, tint: nc.navbarPillText)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slides up 12 dp and fades in, one group after another (SettingsFragment.animateIn).
class _Rise extends StatelessWidget {
  const _Rise({required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final delay = order * 60;
    final total = 320 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 12), child: child),
      ),
      child: child,
    );
  }
}

/// item_settings_section.xml: 13 sp medium text_secondary, 6 dp in, 18 dp above, 8 dp below.
class _Section extends StatelessWidget {
  const _Section(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6, top: 18, bottom: 8),
      child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: NC.of(context).textSecondary)),
    );
  }
}

/// ds_set_card: a white card (16 dp corners) of rows split by 1 dp hairlines inset past the icon.
class _Card extends StatelessWidget {
  const _Card({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return Material(
      color: nc.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 62, end: 16),
                child: Container(height: 1, color: nc.divider),
              ),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// item_settings_row.xml: a 32 dp accent_container circle with the 18 dp glyph in primary, title
/// (15 sp) + value (12 sp text_secondary), 18 dp chevron in navbar_off; at least 60 dp.
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
      splashColor: nc.rowPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: nc.accentContainer, shape: BoxShape.circle),
                child: NativeIcon(icon, size: 18, tint: nc.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
                    if (sub != null) Text(sub, style: TextStyle(fontSize: 12, color: nc.textSecondary)),
                  ],
                ),
              ),
              NativeMirror(child: NativeIcon(ND.icChevronRight, size: 18, tint: nc.navbarOff)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Android row name → its "settings_…_tapped" event (SettingsFragment.row).
String _settingsEvent(String item) => switch (item) {
      'feedback_or_suggestion' => 'settings_feedback_tapped',
      'explore_more_apps' => 'settings_explore_apps_tapped',
      'terms_of_use' => 'settings_terms_tapped',
      'privacy_policy' => 'settings_privacy_tapped',
      'manage_subscriptions' => 'settings_subscriptions_tapped',
      _ => 'settings_${item}_tapped',
    };
