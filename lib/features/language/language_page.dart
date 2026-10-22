import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/banner_slot.dart';

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

  Future<void> _apply() async {
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: c.bgScreen,
        body: Column(
          children: [
            // blue bar: (back only when opened from Settings) "Language" ... check mark
            Material(
              color: c.primary,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      if (!widget.firstLaunch) ...[
                        const SizedBox(width: 4),
                        _BarButton(
                          onTap: () => Navigator.pop(context),
                          child: NativeIcon(ND.icBack, size: 24, tint: c.white),
                        ),
                        const SizedBox(width: 8),
                      ] else
                        const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          s.t('language'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.white),
                        ),
                      ),
                      _BarButton(
                        onTap: _apply,
                        tooltip: s.t('done'),
                        child: NativeIcon(ND.icCheck, size: 24, tint: c.white),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                // "Default" first, then the languages
                itemCount: languages.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _LanguageRow(
                      name: s.t('languageDefault'),
                      selected: selected.isEmpty,
                      onTap: () => setState(() => _selected = ''),
                    );
                  }
                  final lang = languages[index - 1];
                  return _LanguageRow(
                    name: lang.nativeName,
                    selected: selected == lang.tag,
                    onTap: () => setState(() => _selected = lang.tag),
                  );
                },
              ),
            ),
            // AdBar on @color/surface (the nav bar area too)
            ColoredBox(
              color: c.surface,
              child: const SafeArea(top: false, child: BannerSlot(reserveSpace: true)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 48 dp borderless-ripple button of the blue bar (btnBack / btnDone).
class _BarButton extends StatelessWidget {
  const _BarButton({required this.onTap, required this.child, this.tooltip});

  final VoidCallback onTap;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 48,
      height: 48,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          splashColor: const Color(0x33FFFFFF),
          child: Center(child: child),
        ),
      ),
    );
    final text = tooltip;
    return text == null ? button : Tooltip(message: text, child: button);
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
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              height: 58,
              child: Padding(
                padding: const EdgeInsets.only(left: 22, right: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        textAlign: TextAlign.left,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.textPrimary),
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
