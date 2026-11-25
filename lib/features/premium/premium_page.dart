import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/apple_billing.dart';
import '../../services/ios_analytics.dart';
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
    IosAnalytics.activate('premium');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _premiumAtStart = AppScope.of(context).settings.premium;
    // "Get Ready for Your 7-Day Free Trial": on iOS only when App Store Connect really offers this
    // Apple Account a 7-day free trial (never promise a trial that is not there)
    _ready = !_premiumAtStart && (!Platform.isIOS || AppScope.of(context).billing.yearlyTrialDays == 7);
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
    IosAnalytics.left('premium');
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
    final upgrading = premium && _yearly && scope.settings.subscriptionPlan != 'yearly';
    final manage = premium && !upgrading;
    final prices = PlanPrices.of(s, scope.billing);
    final continueLabel = manage ? s.t('manageSubscriptions') : s.t('continueAction');
    final top = MediaQuery.paddingOf(context).top;
    return NativeLightStatusBar(
      child: Scaffold(
        backgroundColor: const Color(0xFF1F2933),
        body: Stack(
          children: [
            // bg_paywall
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1F2933), Color(0xFF0B1F1E)],
                  ),
                ),
              ),
            ),
            Column(
              children: [
                // status bar strip (#FF1F2933 like Theme.DocReader.Premium)
                Container(height: top, color: const Color(0xFF1F2933)),
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
                                colors: [Color(0x000F2A28), Color(0xFF0F2A28)],
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
                  // bg_paywall_body (marginTop -16dp): #103534 with 28 dp top corners
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 184,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                        color: Color(0xFF103534),
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
      // bg_paywall_hero: #14706A → #1F2933 (315°) with a soft teal glow at the end
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomLeft,
            end: Alignment.topRight,
            colors: [Color(0xFF14706A), Color(0xFF1F2933)],
          ),
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
                      // dots: bottom|start, marginStart 18dp, marginBottom 30dp (bg_dot_paywall:
                      // #8FD6CB, the current one 14 dp wide and opaque, the others 6 dp at 35%)
                      PositionedDirectional(
                        start: 15,
                        bottom: 30,
                        child: Row(
                          children: [
                            for (var i = 0; i < _slideCount; i++)
                              Container(
                                width: i == (incoming ?? _slide) ? 14 : 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(horizontal: 3),
                                decoration: BoxDecoration(
                                  color: i == (incoming ?? _slide) ? const Color(0xFF8FD6CB) : const Color(0x598FD6CB),
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
    // Benefit lines only. Prices, plans, and Continue stay as they are.
    const features = [
      (ND.icStSubscriptions, 'featAdFree'),
      (ND.dsToolsIcScan, 'scanToPdf'),
      (ND.dsToolsIcCreatePdf, 'createPdf'),
      (ND.dsToolsIcMerge, 'mergePdf'),
      (ND.dsToolsIcSplit, 'splitPdf'),
      (ND.icStWidget, 'featTemplates'),
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
            colors: const [Color(0xFFD5EFEB), Color(0xFF0D8A7F)],
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
                    Text(s.t('premiumTrustedTop'), style: const TextStyle(color: Color(0xFFCCE7E3), fontSize: 9)),
                    Text(
                      s.t('premiumTrustedCount'),
                      style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    Text(s.t('premiumTrustedBottom'), style: const TextStyle(color: Color(0xFFCCE7E3), fontSize: 9)),
                  ],
                ),
              ),
              const NativeIcon(ND.icLaurelRight, width: 16, height: 24),
            ],
          ),
        ),
        // benefits: a 32 dp ds_prem_ring with the 17 dp glyph in #8FD6CB, 14 sp white text,
        // ic_check_blue (20 dp); 10 dp apart; they rise in one after another
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          child: Column(
            children: [
              for (var i = 0; i < features.length; i++)
                _RiseIn(
                  delay: Duration(milliseconds: (_ready ? _readyMs + 100 : 120) + 40 * i),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0x1FFFFFFF),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF8FD6CB), width: 1.5),
                          ),
                          child: NativeIcon(features[i].$1, size: 17, tint: const Color(0xFF8FD6CB)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.t(features[i].$2),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ),
                        const NativeIcon(ND.icCheckBlue, size: 20),
                      ],
                    ),
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
                  colors: const [Color(0xFF8FD6CB), Color(0xFF0D8A7F)],
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

  /// bg_review_card: #14FFFFFF, 1 dp #1F8FD6CB stroke, 18 dp corners; faint quote top end.
  Widget _reviewCard(String title, String name, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        border: Border.all(color: const Color(0x1F8FD6CB)),
        borderRadius: BorderRadius.circular(18),
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
                      child: Text(name, style: const TextStyle(color: Color(0xFFCCE7E3), fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(text, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12.5, height: 1.5)),
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
      color: const Color(0xFF0F2A28),
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
                      onTap: () {
                        IosAnalytics.planSelected('yearly', 'premium', status: premium ? 'pro' : 'free');
                        setState(() => _yearly = true);
                      },
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
                        // bg_save_pink ("Plum deck"): the action teal, 10 dp corners
                        decoration: const BoxDecoration(
                          color: Color(0xFF0D8A7F),
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                        ),
                        child: Text(
                          s.t('planSavePercent', {'percent': '$save'}),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
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
                onTap: () {
                  IosAnalytics.planSelected('monthly', 'premium', status: premium ? 'pro' : 'free');
                  setState(() => _yearly = false);
                },
              ),
              const SizedBox(height: 16),
              PaywallContinueButton(
                label: continueLabel,
                colors: const [Color(0xFF14A394), Color(0xFF0D8A7F)],
                busy: _busy,
                arrow: !premium,
                onTap: _busy ? null : _continue,
              ),
              if (!premium) ...[
                const SizedBox(height: 12),
                Text(
                  s.t('cancelAnytime'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                ),
                // App Store auto-renewable subscription information (App Review 3.1.2)
                if (Platform.isIOS) ...[
                  const SizedBox(height: 6),
                  Text(
                    s.t('iapAutoRenewInfo'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5, height: 1.35),
                  ),
                ],
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
              color: Color(0xFF94A3B8),
              fontSize: 11,
              decoration: TextDecoration.underline,
              decorationColor: Color(0xFF94A3B8),
            ),
          ),
        ),
      ),
    );
  }

  /// bg_paywall_plan ("Plum deck"): #14FFFFFF with a 1 dp #33FFFFFF hairline; chosen = #268FD6CB
  /// with a 2 dp #8FD6CB outline; 18 dp corners, 62 dp.
  Widget _plan({
    required String title,
    required String subtitle,
    required String price,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: selected
          ? const BorderSide(color: Color(0xFF8FD6CB), width: 2)
          : const BorderSide(color: Color(0x33FFFFFF), width: 1),
    );
    return Material(
      color: selected ? const Color(0x268FD6CB) : const Color(0x14FFFFFF),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: SizedBox(
          height: 62,
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
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(price, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
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
    final upgrading = settings.premium && _yearly && settings.subscriptionPlan != 'yearly';
    if (settings.premium && !upgrading) {
      await openManageSubscriptions(context);
      return;
    }
    IosAnalytics.log('premium_continue_tapped', {'screen': 'premium', 'plan': _yearly ? 'yearly' : 'monthly'});
    setState(() => _busy = true);
    final ok = await buyPremium(context, yearly: _yearly, screen: 'premium');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, s.t('premiumWelcome'));
      Navigator.pop(context);
      return;
    }
    if (settings.premium) return;
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
    IosAnalytics.log('restore_tap', {'screen': 'premium'});
    setState(() => _busy = true);
    final outcome = await AppScope.of(context).billing.restoreOutcome();
    IosAnalytics.restoreResult('premium', restored: outcome == RestoreOutcome.restored, reason: outcome.name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (outcome == RestoreOutcome.restored) {
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
                fontWeight: FontWeight.w500,
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
          decoration: const BoxDecoration(color: Color(0xCC8FD6CB), shape: BoxShape.circle),
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
      color: const Color(0xFF103534),
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
                                colors: [Color(0x590D8A7F), Color(0x268FD6CB), Color(0x008FD6CB)],
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
                              begin: Alignment.bottomLeft,
                              end: Alignment.topRight,
                              colors: [Color(0xFF8FD6CB), Color(0xFF0D8A7F)],
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
                        colors: const [Color(0xFFD5EFEB), Color(0xFF8FD6CB)],
                        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w500, fontStyle: FontStyle.italic),
                      ),
                    ),
                    _line(
                      1,
                      PaywallGradientText(
                        s.t('readyBottom'),
                        textAlign: TextAlign.center,
                        colors: const [Color(0xFF8FD6CB), Color(0xFF0D8A7F)],
                        style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w500, fontStyle: FontStyle.italic),
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

/// Slides up 12 dp and fades in after [delay] (the benefit rows of PremiumActivity).
class _RiseIn extends StatelessWidget {
  const _RiseIn({required this.delay, required this.child});

  final Duration delay;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    final total = delay.inMilliseconds + 260;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay.inMilliseconds / total, 1, curve: const Cubic(0.4, 0, 0.2, 1)),
      builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child)),
      child: child,
    );
  }
}
