import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../widgets/banner_slot.dart';
import '../../services/ios_analytics.dart';
import '../../widgets/chrome.dart';

/// Language: "Default" (the phone's language) and the 23 app languages; a banner ad at the bottom
/// ("Loading ad…" until it arrives). On the first start it also asks for the notification
/// permission (Android 13+), like the Android app.
class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key, this.firstLaunch = false, this.onDone});

  final bool firstLaunch;
  final VoidCallback? onDone;

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  @override
  void initState() {
    super.initState();
    IosAnalytics.activate('language');
    if (widget.firstLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askNotifications());
    }
  }

  Future<void> _askNotifications() async {
    if (!Platform.isAndroid || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    } catch (error) {
      debugPrint('notification permission: $error');
    }
  }

  /// The row ticked on screen; applied only with the check mark, like the Android app.
  /// '' = "Default" (the phone's language).
  String? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selected != null) return;
    final settings = AppScope.of(context).settings;
    _selected = settings.languageSystem ? '' : settings.languageTag;
  }

  @override
  void dispose() {
    IosAnalytics.left('language');
    super.dispose();
  }

  Future<void> _apply() async {
    IosAnalytics.log('language_done_tapped', {'screen': 'language', 'language': _selected ?? 'system'});
    final settings = AppScope.of(context).settings;
    final tag = _selected ?? '';
    await settings.setLanguage(tag.isEmpty ? settings.languageTag : tag, system: tag.isEmpty);
    if (!mounted) return;
    if (widget.firstLaunch) {
      widget.onDone?.call();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final selected = _selected ?? '';
    final dark = Theme.of(context).brightness == Brightness.dark;
    // activity_language.xml ("Plum deck"): a page-coloured bar (back circle when opened from
    // Settings, "Language" as the screen title, the accent ✓ circle) and white card rows
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: c.bgScreen,
        body: Column(
          children: [
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    if (!widget.firstLaunch) ...[
                      const SizedBox(width: 6),
                      DsTopBack(onTap: () {
                        IosAnalytics.back('language');
                        Navigator.pop(context);
                      }),
                      const SizedBox(width: 6),
                    ] else
                      const SizedBox(width: 16),
                    Expanded(
                      child: Text(s.t('language'), maxLines: 1, overflow: TextOverflow.ellipsis, style: dsScreenTitle(context)),
                    ),
                    DsCircleButton(
                      fill: c.accent,
                      circle: 44,
                      icon: ND.icCheck,
                      tint: c.onAccent,
                      iconPadding: 13,
                      tooltip: s.t('done'),
                      onTap: _apply,
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                // "Default" first, then the languages
                itemCount: languages.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _LanguageRow(
                      name: s.t('languageDefault'),
                      selected: selected.isEmpty,
                      onTap: () {
                        IosAnalytics.log('language_selected', {'item': 'system', 'screen': 'language'});
                        setState(() => _selected = '');
                      },
                    );
                  }
                  final lang = languages[index - 1];
                  return _LanguageRow(
                    name: lang.nativeName,
                    selected: selected == lang.tag,
                    onTap: () {
                      IosAnalytics.log('language_selected', {'item': lang.tag, 'screen': 'language'});
                      setState(() => _selected = lang.tag);
                    },
                  );
                },
              ),
            ),
            // AdBar on the page colour (the nav bar area too)
            ColoredBox(
              color: c.bgScreen,
              child: const SafeArea(top: false, child: BannerSlot(unit: 2, testAd: true)),
            ),
          ],
        ),
      ),
    );
  }
}

/// item_language.xml: 58 dp bg_card_ripple card (surface, 10 dp), 4 dp apart, the bold 17 sp name
/// on the left (also in Arabic / Persian / Urdu, layoutDirection ltr) and a radio_tint radio
/// button on the right.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.name, required this.selected, required this.onTap});

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // ds_a_lang_row: a white card (16 dp corners); the chosen one accent_container with a
      // 1.5 dp accent edge
      child: Material(
        color: selected ? c.accentContainer : c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: selected ? BorderSide(color: c.accent, width: 1.5) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          splashColor: c.rowPressed,
          onTap: onTap,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        textAlign: TextAlign.left,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.textPrimary),
                      ),
                    ),
                    // MaterialRadioButton: 48 dp touch area, 20 dp ring
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: CustomPaint(
                          size: const Size.square(20),
                          painter: _RadioPainter(selected: selected, color: selected ? c.primary : c.radioOff),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Material radio button: a 2 dp ring, with a 10 dp dot when checked.
class _RadioPainter extends CustomPainter {
  const _RadioPainter({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..isAntiAlias = true,
    );
    if (selected) canvas.drawCircle(center, radius / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _RadioPainter oldDelegate) => oldDelegate.selected != selected || oldDelegate.color != color;
}
