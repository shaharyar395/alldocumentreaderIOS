import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';
import '../settings/app_links.dart';
import '../settings/native_bars.dart';
import '../settings/settings_tab.dart';
import '../settings/terms_page.dart';
import 'paywall_ui.dart';
import 'purchase_flow.dart';
import 'start_trial_page.dart';

/// Get Premium like the Android PremiumActivity (activity_premium.xml): "Get Ready for Your
/// 7-Day Free Trial" for a moment, then the dark paywall: feature pictures that slide in from
/// the right every 3 s (swipe works too), "Get Premium", benefits, user reviews, and — fixed at
/// the bottom — the 7-day-trial Yearly plan ("Save N%", price per day) and Monthly, Continue
/// (→ "Start Free Trial" page when the store sheet closes without a purchase), Terms | Privacy.
/// Restore at the top end; the X shows up after 3 s. With Premium on, Continue becomes
/// "Manage subscriptions".
class PremiumPage extends StatefulWidget {
  const PremiumPage({super.key});

  @override
  State<PremiumPage> createState() => _PremiumPageState();
}

/// How long "Get Ready for Your 7-Day Free Trial" stays before the page (READY_MS).
const _readyMs = 1700;

class _PremiumPageState extends State<PremiumPage> with TickerProviderStateMixin {
  bool _yearly = true;
  bool _busy = false;

  // ---- hero slides: two views take turns (current leaves, next slides in), 420 ms
  int _slide = 0;
  int? _incoming;
  bool _forward = true;
  Timer? _auto;
  late final AnimationController _slideAnim;
  static const _slideCount = 6;

  // ---- "Get Ready" screen
  bool _ready = false;
  bool _readyFading = false;
  Timer? _readyTimer;
  bool _premiumAtStart = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _slideAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _premiumAtStart = AppScope.of(context).settings.premium;
    _ready = !_premiumAtStart;
    if (_ready) {
      _readyTimer = Timer(const Duration(milliseconds: _readyMs), () {
        if (!mounted) return;
        setState(() => _readyFading = true);
        _readyTimer = Timer(const Duration(milliseconds: 260), () {
          if (mounted) setState(() => _ready = false);
        });
      });
    }
    _restartAuto();
  }

  @override
  void dispose() {
    _auto?.cancel();
    _readyTimer?.cancel();
    _slideAnim.dispose();
    super.dispose();
  }

  void _restartAuto() {
    _auto?.cancel();
    _auto = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _goTo(_slide + 1);
      _restartAuto();
    });
  }

  Future<void> _goTo(int target, {bool forward = true}) async {
    if (_slideAnim.isAnimating) return;
    final next = ((target % _slideCount) + _slideCount) % _slideCount;
    if (next == _slide) return;
    setState(() {
      _incoming = next;
      _forward = forward;
    });
    _restartAuto();
    await _slideAnim.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _slide = next;
      _incoming = null;
    });
    _slideAnim.value = 0;
  }

  /// Back from "Start Free Trial": the pictures start again from "Remove ads".
  void _restartSlides() {
    _slideAnim.stop();
    _slideAnim.value = 0;
    setState(() {
      _slide = 0;
      _incoming = null;
    });
    _restartAuto();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final scope = AppScope.of(context);
    final premium = scope.settings.premium;
    final prices = PlanPrices.of(s, scope.billing);
    final continueLabel = premium
        ? s.t('manageSubscriptions')
        : _yearly && prices.trialDays > 0
            ? s.t('startFreeTrial')
            : s.t('continueAction');
    final top = MediaQuery.paddingOf(context).top;
    return NativeLightStatusBar(
      child: Scaffold(
        backgroundColor: const Color(0xFF16171C),
        body: Stack(
          children: [
            // bg_paywall
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF16171C), Color(0xFF14152E), Color(0xFF0E0F1E)],
                  ),
                ),
              ),
            ),
            Column(
              children: [
                // status bar strip (#FF1A1B20 like Theme.DocReader.Premium)
                Container(height: top, color: const Color(0xFF1A1B20)),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _scrollContent(context, s, premium)),
                      // bg_paywall_fade above the fixed panel
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 36,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x00111229), Color(0xFF111229)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _bottomPanel(context, s, prices, premium, continueLabel),
              ],
            ),
            // X (after 3 s, + the Get Ready time) and Restore
            Positioned(
              top: top + 4,
              left: 0,
              right: 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 6),
                  PaywallRevealClose(
                    delay: Duration(milliseconds: 3000 + (_premiumAtStart ? 0 : _readyMs)),
                    tooltip: s.t('cancel'),
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 2, end: 6),
                    child: PaywallRestoreButton(
                      label: s.t('restore'),
                      color: const Color(0xD9FFFFFF),
                      onTap: _busy ? null : _restore,
                    ),
                  ),
                ],
              ),
            ),
            if (_ready)
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _readyFading ? 0 : 1,
                  duration: const Duration(milliseconds: 260),
                  child: const _ReadyView(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _scrollContent(BuildContext context, S s, bool premium) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(overscroll: false, scrollbars: false),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Stack(
                children: [
                  Positioned(left: 0, right: 0, top: 0, height: 200, child: _hero(s)),
                  // bg_paywall_body (marginTop -16dp, 22dp top corners)
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 184,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xFF2B2F7A), Color(0xFF1C1D4C), Color(0xFF111229)],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 184 + 16, 18, 28),
                    child: _body(s, premium),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ hero

  List<(String, NDrawable)> _slides(S s) => [
        (s.t('removeAds'), ND.illPremAds),
        (s.t('premiumSlideSign'), ND.illPremSign),
        (s.t('premiumSlideConvert'), ND.illPremConvert),
        (s.t('slideTemplates'), ND.illPremTemplates),
        (s.t('slidePages'), ND.illPremPages),
        (s.t('premiumSlideMerge'), ND.illPremMerge),
      ];

  Widget _hero(S s) {
    final slides = _slides(s);
    final incoming = _incoming;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v.abs() < 50) return;
        _goTo(v < 0 ? _slide + 1 : _slide - 1, forward: v < 0);
      },
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF1A1B20), Color(0xFF2A2C33), Color(0xFF15161A)]),
        ),
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              return AnimatedBuilder(
                animation: _slideAnim,
                builder: (context, _) {
                  // ViewPropertyAnimator's default AccelerateDecelerateInterpolator
                  final t = Curves.easeInOutSine.transform(_slideAnim.value);
                  final sign = _forward ? 1.0 : -1.0;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Transform.translate(
                          offset: Offset(incoming == null ? 0 : -sign * w * t, 0),
                          child: _HeroSlide(title: slides[_slide].$1, art: slides[_slide].$2),
                        ),
                      ),
                      if (incoming != null)
                        Positioned.fill(
                          child: Transform.translate(
                            offset: Offset(sign * w * (1 - t), 0),
                            child: _HeroSlide(title: slides[incoming].$1, art: slides[incoming].$2),
                          ),
                        ),
                      // dots: bottom|start, marginStart 18dp, marginBottom 30dp (bg_dot_paywall)
                      PositionedDirectional(
                        start: 18,
                        bottom: 30,
                        child: Row(
                          children: [
                            for (var i = 0; i < _slideCount; i++)
                              Container(
                                width: i == (incoming ?? _slide) ? 14 : 4,
                                height: 4,
                                margin: const EdgeInsetsDirectional.only(end: 5),
                                decoration: BoxDecoration(
                                  color: i == (incoming ?? _slide) ? Colors.white : const Color(0x66FFFFFF),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ body

  Widget _body(S s, bool premium) {
    const features = [
      (ND.icQAds, 'featAdFree'),
      (ND.icQEdit, 'featEditSign'),
      (ND.icStTerms, 'featConvert'),
      (ND.icStWidget, 'featTemplates'),
      (ND.icPages, 'featPages'),
      (ND.icFeatMerge, 'featMerge'),
    ];
    const reviews = [
      ('review1Title', 'review1Name', 'review1Text'),
      ('review2Title', 'review2Name', 'review2Text'),
      ('review3Title', 'review3Name', 'review3Text'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: PaywallGradientText(
            s.t('getPremium'),
            textAlign: TextAlign.center,
            colors: const [Color(0xFF6FA8FF), Color(0xFFB18CFF)],
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
        ),
        if (premium)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              s.t('premiumActive'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
            ),
          ),
        // laurels: Loved by / our users / worldwide
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const NativeIcon(ND.icLaurelLeft, width: 16, height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Column(
                  children: [
                    Text(s.t('premiumTrustedTop'), style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 9)),
                    Text(
                      s.t('premiumTrustedCount'),
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(s.t('premiumTrustedBottom'), style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 9)),
                  ],
                ),
              ),
              const NativeIcon(ND.icLaurelRight, width: 16, height: 24),
            ],
          ),
        ),
        // benefits: 38dp rows, white 18dp icon, 14sp text, ic_check_blue
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          child: Column(
            children: [
              for (final f in features)
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      NativeIcon(f.$1, size: 18, tint: Colors.white),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          s.t(f.$2),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      const NativeIcon(ND.icCheckBlue, size: 18),
                    ],
                  ),
                ),
            ],
          ),
        ),
        // User Reviews (face + gradient text + sparkle)
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const NativeIcon(ND.icReviewFace, size: 18),
              const SizedBox(width: 4),
              Flexible(
                child: PaywallGradientText(
                  s.t('userReviews'),
                  colors: const [Color(0xFF5B8CFF), Color(0xFFA9BCFF)],
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
              const NativeIcon(ND.icReviewSparkle, size: 10),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final r in reviews) _reviewCard(s.t(r.$1), s.t(r.$2), s.t(r.$3)),
      ],
    );
  }

  /// bg_review_card: #14FFFFFF, 1dp #1FFFFFFF stroke, 14dp corners; faint quote top end.
  Widget _reviewCard(String title, String name, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        border: Border.all(color: const Color(0x1FFFFFFF)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        children: [
          const PositionedDirectional(top: 6, end: 10, child: NativeIcon(ND.icQuoteBig, size: 40)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (var i = 0; i < 5; i++)
                      const Padding(
                        padding: EdgeInsetsDirectional.only(end: 3),
                        child: NativeIcon(ND.icStarFilled, size: 15),
                      ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(name, style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(text, style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12.5, height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ plans

  Widget _bottomPanel(BuildContext context, S s, PlanPrices prices, bool premium, String continueLabel) {
    final save = prices.savePercent;
    return ColoredBox(
      color: const Color(0xFF111229),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Yearly with free trial + "Save N%" tag on its top end corner
              Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _plan(
                      title: prices.trialDays > 0
                          ? s.t('planTrialDays', {'days': '${prices.trialDays}'})
                          : s.t('yearly'),
                      subtitle: prices.trialDays > 0
                          ? s.t('planThenOnlyPerDay', {'price': prices.yearlyPerDay})
                          : s.t('planPerDay', {'price': prices.yearlyPerDay}),
                      price: s.t('planPriceYear', {'price': prices.yearly}),
                      selected: _yearly,
                      onTap: () => setState(() => _yearly = true),
                    ),
                  ),
                  if (save != null)
                    PositionedDirectional(
                      top: 0,
                      end: 0,
                      child: Container(
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [Color(0xFFFF3B6B), Color(0xFFD03BFF)]),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(8),
                            topRight: Radius.circular(8),
                            bottomLeft: Radius.circular(2),
                            bottomRight: Radius.circular(8),
                          ),
                        ),
                        child: Text(
                          s.t('planSavePercent', {'percent': '$save'}),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _plan(
                title: s.t('monthly'),
                subtitle: s.t('planPerDay', {'price': prices.monthlyPerDay}),
                price: s.t('planPriceMonth', {'price': prices.monthly}),
                selected: !_yearly,
                onTap: () => setState(() => _yearly = false),
              ),
              const SizedBox(height: 16),
              PaywallContinueButton(
                label: continueLabel,
                colors: const [Color(0xFF3E5BFF), Color(0xFF7C3FF2)],
                busy: _busy,
                arrow: !premium,
                onTap: _busy ? null : _continue,
              ),
              if (!premium) ...[
                const SizedBox(height: 12),
                Text(
                  s.t('cancelAnytime'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _link(
                    s.t('termsOfUse'),
                    () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TermsPage())),
                  ),
                  const Text('|', style: TextStyle(color: Color(0x4DFFFFFF), fontSize: 11)),
                  _link(s.t('privacyPolicy'), () {
                    final scope = AppScope.of(context);
                    scope.guard.arm(scope.settings);
                    launchUrl(Uri.parse(privacyPolicyUrl), mode: LaunchMode.externalApplication);
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _link(String label, VoidCallback onTap) {
    return Flexible(
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0x80FFFFFF),
              fontSize: 11,
              decoration: TextDecoration.underline,
              decorationColor: Color(0x80FFFFFF),
            ),
          ),
        ),
      ),
    );
  }

  /// bg_paywall_plan: #232559, selected #26296A with a 1.5dp #8C8FFF stroke; 12dp corners, 58dp.
  Widget _plan({
    required String title,
    required String subtitle,
    required String price,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: selected ? const BorderSide(color: Color(0xFF8C8FFF), width: 1.5) : BorderSide.none,
    );
    return Material(
      color: selected ? const Color(0xFF26296A) : const Color(0xFF232559),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(price, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ buy / restore

  Future<void> _continue() async {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    if (settings.premium) {
      await openManageSubscriptions(context);
      return;
    }
    setState(() => _busy = true);
    final ok = await buyPremium(context, yearly: _yearly);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, s.t('premiumWelcome'));
      Navigator.pop(context);
      return;
    }
    // like the Android app: when the store sheet closes without a purchase (or can't open),
    // "Start Free Trial" comes up (fade); its X brings the user back here
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => const StartTrialPage(),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      ),
    );
    if (!mounted) return;
    if (settings.premium) {
      Navigator.pop(context);
      return;
    }
    // back from "Start Free Trial": the pictures start again from "Remove ads"
    _restartSlides();
  }

  Future<void> _restore() async {
    final s = S.of(context);
    setState(() => _busy = true);
    final ok = await AppScope.of(context).billing.restore();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, s.t('premiumRestored'));
    } else {
      showTopPill(context, s.t('noSubscription'));
    }
  }
}

/// item_premium_slide.xml: the picture at the bottom end (220dp wide, 24dp top padding,
/// fitEnd) and the 21sp bold white title (150dp wide, shadow) at the start.
class _HeroSlide extends StatelessWidget {
  const _HeroSlide({required this.title, required this.art});

  final String title;
  final NDrawable art;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PositionedDirectional(
          end: 0,
          top: 24,
          bottom: 0,
          width: 220,
          child: FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.bottomRight,
            child: NativeIcon(art, width: art.width, height: art.height),
          ),
        ),
        PositionedDirectional(
          start: 18,
          top: 0,
          bottom: 12,
          width: 150,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Get Ready for Your 7-Day Free Trial": the red → orange ball with the check pops in
/// (overshoot), its glow pulses, three dots twinkle and the two lines rise in.
class _ReadyView extends StatefulWidget {
  const _ReadyView();

  @override
  State<_ReadyView> createState() => _ReadyViewState();
}

class _ReadyViewState extends State<_ReadyView> with TickerProviderStateMixin {
  late final AnimationController _ball =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450))..forward();
  late final AnimationController _glow =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
  late final List<AnimationController> _sparks = [
    for (var i = 0; i < 3; i++) AnimationController(vsync: this, duration: Duration(milliseconds: 520 + i * 130)),
  ];
  late final List<AnimationController> _lines = [
    for (var i = 0; i < 2; i++) AnimationController(vsync: this, duration: const Duration(milliseconds: 380)),
  ];
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _sparks.length; i++) {
      _timers.add(Timer(Duration(milliseconds: i * 160), () {
        if (mounted) _sparks[i].repeat(reverse: true);
      }));
    }
    for (var i = 0; i < _lines.length; i++) {
      _timers.add(Timer(Duration(milliseconds: 220 + i * 120), () {
        if (mounted) _lines[i].forward();
      }));
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _ball.dispose();
    _glow.dispose();
    for (final c in [..._sparks, ..._lines]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _spark(int i, double left, double top, double size) {
    return Positioned(
      left: left,
      top: top,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.15, end: 1).animate(_sparks[i]),
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(color: Color(0xCCB9C4FF), shape: BoxShape.circle),
        ),
      ),
    );
  }

  Widget _line(int i, Widget child) {
    return AnimatedBuilder(
      animation: _lines[i],
      builder: (context, child) => Opacity(
        opacity: _lines[i].value,
        child: Transform.translate(offset: Offset(0, 14 * (1 - _lines[i].value)), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ColoredBox(
      color: const Color(0xFF16171C),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _ball,
                builder: (context, child) {
                  final v = _ball.value;
                  final scale = 0.5 + 0.5 * const _Overshoot(1.6).transform(v);
                  return Opacity(opacity: v, child: Transform.scale(scale: scale, child: child));
                },
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: Stack(
                    children: [
                      // bg_ready_glow: radial #66 → #33 → #00 FF5A3C, pulsing 0.55 ↔ 1
                      Positioned.fill(
                        child: FadeTransition(
                          opacity: Tween<double>(begin: 0.55, end: 1).animate(_glow),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [Color(0x66FF5A3C), Color(0x33FF5A3C), Color(0x00FF5A3C)],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // bg_ready_circle (elevation 6) with ic_ready_check
                      Center(
                        child: Container(
                          width: 96,
                          height: 96,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFFF3D3D), Color(0xFFFF6A3D), Color(0xFFFFC56E)],
                            ),
                            boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 8, offset: Offset(0, 3))],
                          ),
                          alignment: Alignment.center,
                          child: const NativeIcon(ND.icReadyCheck, size: 52),
                        ),
                      ),
                      _spark(0, 44, 30, 5),
                      _spark(1, 132, 22, 4),
                      _spark(2, 150, 40, 3),
                    ],
                  ),
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -20),
                child: Column(
                  children: [
                    _line(
                      0,
                      PaywallGradientText(
                        s.t('readyTop'),
                        textAlign: TextAlign.center,
                        colors: const [Color(0xFFFF5A3C), Color(0xFFFFB259)],
                        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700, fontStyle: FontStyle.italic),
                      ),
                    ),
                    _line(
                      1,
                      PaywallGradientText(
                        s.t('readyBottom'),
                        textAlign: TextAlign.center,
                        colors: const [Color(0xFFFF4B3A), Color(0xFFFFC56E)],
                        style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700, fontStyle: FontStyle.italic),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Android OvershootInterpolator(tension).
class _Overshoot extends Curve {
  const _Overshoot(this.tension);

  final double tension;

  @override
  double transformInternal(double t) {
    final x = t - 1;
    return x * x * ((tension + 1) * x + tension) + 1;
  }
}
