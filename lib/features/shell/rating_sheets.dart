import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../widgets/chrome.dart';
import '../settings/feedback_page.dart';

const _androidPackage = 'com.theoccess.alldocreader';

/// "Do you think All Document Reader is helpful?" — like the Android app: after the 1st saved /
/// converted file, then after every 3 more, at most once a day, never again once answered.
class HelpfulPrompt {
  HelpfulPrompt._();

  static bool _shownThisRun = false;

  /// True while the helpful sheet is on screen.
  static bool showing = false;

  static bool shouldShow(AppSettings settings) {
    if (_shownThisRun || settings.helpfulAnswered) return false;
    final need = settings.helpfulShownAt == 0 ? 1 : 3;
    if (settings.savesSinceHelpful < need) return false;
    final since = DateTime.now().millisecondsSinceEpoch - settings.helpfulShownAt;
    return since >= const Duration(hours: 24).inMilliseconds;
  }

  static Future<void> show(BuildContext context) async {
    final settings = AppScope.of(context).settings;
    _shownThisRun = true;
    showing = true;
    await settings.markHelpfulShown();
    if (!context.mounted) {
      showing = false;
      return;
    }
    final choice = await _showClearSheet<String>(context, const _HelpfulSheet());
    showing = false;
    if (!context.mounted || choice == null) return;
    await settings.markHelpfulAnswered();
    if (!context.mounted) return;
    if (choice == 'yes') {
      await showRateSheet(context);
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FeedbackPage()));
    }
  }
}

/// Theme.DocReader.BottomSheet.Transparent: the sheet's content draws its own background (the
/// card with the mascot sticking out above it); opens fully expanded.
Future<T?> _showClearSheet<T>(BuildContext context, Widget sheet) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: const RoundedRectangleBorder(),
    builder: (_) => sheet,
  );
}

/// The mascot bobbing 6 dp up and back (1200 ms each way).
class _Bob extends StatefulWidget {
  const _Bob({required this.child});
  final Widget child;

  @override
  State<_Bob> createState() => _BobState();
}

class _BobState extends State<_Bob> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);
  late final CurvedAnimation _curve = CurvedAnimation(parent: _c, curve: Curves.easeInOut);

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Transform.translate(offset: Offset(0, -6 * _curve.value), child: child),
      child: widget.child,
    );
  }
}

/// sheet_helpful.xml: a bg_rate_card card 64 dp below the top with the bobbing mascot (130 dp)
/// and a beating heart over its edge, the 22 sp bold question, "Not really" (gray pill) and
/// "Yes, helpful" (blue pill), and an × at the top end.
class _HelpfulSheet extends StatefulWidget {
  const _HelpfulSheet();

  @override
  State<_HelpfulSheet> createState() => _HelpfulSheetState();
}

class _HelpfulSheetState extends State<_HelpfulSheet> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 450))
    ..repeat(reverse: true);
  late final CurvedAnimation _beatCurve = CurvedAnimation(parent: _beat, curve: Curves.easeInOut);

  @override
  void dispose() {
    _beatCurve.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 64),
          width: double.infinity,
          decoration: NS.bgRateCard(context),
          padding: EdgeInsets.fromLTRB(20, 64, 20, 28 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s.t('helpfulTitle', {'app': 'All Document Reader'}),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, 'no'),
                        style: FilledButton.styleFrom(
                          backgroundColor: c.btnGray,
                          foregroundColor: c.textPrimary,
                          overlayColor: const Color(0x1F000000),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        child: Text(s.t('helpfulNo'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, 'yes'),
                        style: FilledButton.styleFrom(
                          backgroundColor: c.primary,
                          foregroundColor: c.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        child: Text(s.t('helpfulYes'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // pinned to the top of the sheet; an Align here would stretch the sheet to full height
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: _Bob(
              child: SizedBox(
                width: 130,
                height: 130,
                child: Stack(
                  children: [
                    Positioned.fill(child: NativeIcon(ND.icMascot)),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 6,
                      child: Center(
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 1, end: 1.15).animate(_beatCurve),
                          child: NativeIcon(ND.icHelpfulHeart, size: 44),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        PositionedDirectional(
          top: 70,
          end: 6,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Material(
              type: MaterialType.transparency,
              child: InkResponse(
                onTap: () => Navigator.pop(context),
                radius: 22,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: NativeIcon(ND.icClose, tint: c.textSecondary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Do you like our app?" with 5 tappable stars; 4–5 stars open the store page.
Future<void> showRateSheet(BuildContext context) async {
  final scope = AppScope.of(context);
  await scope.settings.markRateShown();
  if (!context.mounted) return;
  final stars = await _showClearSheet<int>(context, const _RateSheet());
  if (!context.mounted || stars == null || stars <= 0) return;
  final s = S.of(context);
  if (stars < 4 || !Platform.isAndroid) {
    // (iOS: the App Store id is not known yet, so there is no store page to open)
    showToast(context, s.t('rateThanks'));
    return;
  }
  scope.guard.arm(scope.settings);
  var opened = false;
  try {
    opened = await launchUrl(Uri.parse('market://details?id=$_androidPackage'), mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened) {
    try {
      opened = await launchUrl(
        Uri.parse('https://play.google.com/store/apps/details?id=$_androidPackage'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
  }
  if (!opened && context.mounted) showToast(context, s.t('rateThanks'));
}

/// OvershootInterpolator(tension).
class _Overshoot extends Curve {
  const _Overshoot(this.tension);
  final double tension;

  @override
  double transformInternal(double t) {
    final x = t - 1;
    return x * x * ((tension + 1) * x + tension) + 1;
  }
}

/// sheet_rate.xml: a bg_rate_card card 64 dp below the top with the bobbing mascot (120 dp) over
/// its edge, "Do you like `<our app>`?" (22 sp bold, the app part in primary), the subtitle, five
/// 38 dp stars in 52 dp glows (the 5th wiggles ±12°), "The best we can get" with a curved arrow
/// and the Rate pill (#C3D7F7 until a star is chosen).
class _RateSheet extends StatefulWidget {
  const _RateSheet();

  @override
  State<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<_RateSheet> with SingleTickerProviderStateMixin {
  int _rating = 0;

  /// Counts the taps, so the stars' pop-in animation starts again on every tap.
  int _pop = 0;

  // the 5th star gently wiggles to invite a rating, like the Android app
  late final AnimationController _wiggle = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))
    ..repeat(reverse: true);
  late final CurvedAnimation _wiggleCurve = CurvedAnimation(parent: _wiggle, curve: Curves.easeInOut);

  @override
  void dispose() {
    _wiggleCurve.dispose();
    _wiggle.dispose();
    super.dispose();
  }

  Widget _title(S s, NC c) {
    final title = s.t('rateTitle');
    final part = s.t('rateTitleHighlight');
    final at = part.isEmpty ? -1 : title.indexOf(part);
    final style = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.textPrimary);
    if (at < 0) return Text(title, textAlign: TextAlign.center, style: style);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: title.substring(0, at)),
          TextSpan(text: part, style: TextStyle(color: c.primary)),
          TextSpan(text: title.substring(at + part.length)),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _star(int i, NC c) {
    final filled = i < _rating;
    final NDrawable art = filled
        ? ND.icStarFilled
        : (i == 4 && _rating == 0)
            ? ND.icStarHint
            : ND.icStarEmpty;
    Widget star = NativeIcon(art, size: 38);
    if (filled && _pop > 0) {
      final delay = i * 50;
      final total = 260 + delay;
      star = TweenAnimationBuilder<double>(
        key: ValueKey('pop$_pop-$i'),
        tween: Tween(begin: 0.5, end: 1),
        duration: Duration(milliseconds: total),
        curve: Interval(delay / total, 1, curve: const _Overshoot(3)),
        builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
        child: star,
      );
    }
    if (i == 4) {
      star = AnimatedBuilder(
        animation: _wiggleCurve,
        builder: (context, child) => Transform.rotate(angle: (-12 + 24 * _wiggleCurve.value) * math.pi / 180, child: child),
        child: star,
      );
    }
    return Semantics(
      button: true,
      label: '${i + 1}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _rating = i + 1;
          _pop++;
        }),
        child: Container(
          width: 52,
          height: 52,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: filled ? NS.bgStarGlow(context) : null,
          alignment: Alignment.center,
          child: star,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 64),
          width: double.infinity,
          decoration: NS.bgRateCard(context),
          padding: EdgeInsets.fromLTRB(20, 56, 20, 20 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _title(s, c),
              const SizedBox(height: 6),
              Text(s.t('rateSubtitle'), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: c.textSecondary)),
              const SizedBox(height: 16),
              SizedBox(
                height: 60,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [for (var i = 0; i < 5; i++) _star(i, c)],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        s.t('rateBest'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFFFFA000)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
                      child: NativeIcon(ND.icCurvedArrow, width: 30, height: 20),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _rating > 0 ? () => Navigator.pop(context, _rating) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    foregroundColor: c.white,
                    disabledBackgroundColor: const Color(0xFFC3D7F7),
                    disabledForegroundColor: c.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: Text(s.t('rate'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
        // pinned to the top of the sheet; an Align here would stretch the sheet to full height
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(child: _Bob(child: NativeIcon(ND.icMascot, size: 120))),
        ),
      ],
    );
  }
}
