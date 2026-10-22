import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';
import '../settings/native_bars.dart';
import 'paywall_ui.dart';
import 'purchase_flow.dart';

/// "Start Free Trial" like the Android StartTrialActivity: Today (unlock everything) → Get full
/// access → Day 7 (no charge if cancelled 24 h before), "Try 7 Days for Free", Continue (yearly
/// plan with its trial), Restore. A failed purchase shows the orange "Subscribe failed" pill;
/// the X (after 3 s) goes back to Get Premium.
class StartTrialPage extends StatefulWidget {
  const StartTrialPage({super.key});

  @override
  State<StartTrialPage> createState() => _StartTrialPageState();
}

class _StartTrialPageState extends State<StartTrialPage> {
  bool _busy = false;

  Future<void> _buy() async {
    final s = S.of(context);
    setState(() => _busy = true);
    final ok = await buyPremium(context, yearly: true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, s.t('premiumWelcome'));
      Navigator.pop(context);
    } else {
      showTopPill(context, s.t('subscribeFailed'));
    }
  }

  Future<void> _restore() async {
    final s = S.of(context);
    setState(() => _busy = true);
    final ok = await AppScope.of(context).billing.restore();
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      showToast(context, s.t('premiumRestored'));
      Navigator.pop(context);
    } else {
      showTopPill(context, s.t('noSubscription'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final prices = PlanPrices.of(s, AppScope.of(context).billing);
    final top = MediaQuery.paddingOf(context).top;
    // activity_start_trial.xml on bg_trial (#1C3A4C → #15212B → #111317)
    return NativeLightStatusBar(
      child: Scaffold(
        backgroundColor: const Color(0xFF111317),
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1C3A4C), Color(0xFF15212B), Color(0xFF111317)],
                  ),
                ),
              ),
            ),
            Column(
              children: [
                Expanded(
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(overscroll: false, scrollbars: false),
                    child: ListView(
                      physics: const ClampingScrollPhysics(),
                      padding: EdgeInsets.only(top: top + 68, bottom: 16),
                      children: [
                        Text(
                          s.t('startFreeTrial'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        const SizedBox(height: 40),
                        // timeline: the grey line (24dp, #2E343C, 12dp corners) is as tall as the steps
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 24, 6),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              const PositionedDirectional(
                                start: 0,
                                top: -6,
                                bottom: -6,
                                width: 24,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Color(0xFF2E343C),
                                    borderRadius: BorderRadius.all(Radius.circular(12)),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsetsDirectional.only(start: 1),
                                child: Column(
                                  children: [
                                    _step(ND.icTrialLock, s.t('trialToday'), s.t('trialTodaySub')),
                                    const SizedBox(height: 40),
                                    _step(ND.icTrialShield, s.t('trialFullAccess'), s.t('trialFullAccessSub')),
                                    const SizedBox(height: 40),
                                    _step(ND.icTrialCalendar, s.t('trialDay7'), s.t('trialDay7Sub')),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // bg_trial_card: #1C1F25 with 18dp top corners
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF1C1F25),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 26, 18, 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(
                                  s.t('tryDaysFree', {'days': '${prices.trialDays}'}),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // bg_hot: orange gradient, 4dp corners, 16dp tall
                              Container(
                                height: 16,
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(colors: [Color(0xFFFF7A1A), Color(0xFFFF4D1A)]),
                                  borderRadius: BorderRadius.all(Radius.circular(4)),
                                ),
                                child: Text(
                                  s.t('hot'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.t('tryThen', {'price': prices.yearly, 'perDay': prices.yearlyPerDay}),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                          ),
                          const SizedBox(height: 22),
                          PaywallContinueButton(
                            label: s.t('continueAction'),
                            colors: const [Color(0xFF1E8BFF), Color(0xFF1463E6)],
                            busy: _busy,
                            onTap: _busy ? null : _buy,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // X (after 3 s) and Restore
            Positioned(
              top: top + 4,
              left: 0,
              right: 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 6),
                  PaywallRevealClose(
                    delay: const Duration(seconds: 3),
                    tooltip: s.t('cancel'),
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 2, end: 6),
                    child: PaywallRestoreButton(
                      label: s.t('restore'),
                      color: const Color(0x80FFFFFF),
                      onTap: _busy ? null : _restore,
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

  /// One stop of the Today → Get full access → Day 7 timeline (22dp icon, 16sp bold title,
  /// 11sp #80FFFFFF line).
  Widget _step(NDrawable icon, String title, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NativeIcon(icon, size: 22),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(body, style: const TextStyle(color: Color(0x80FFFFFF), fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
