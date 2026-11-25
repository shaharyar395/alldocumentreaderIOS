import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/apple_billing.dart';
import '../../services/ios_analytics.dart';
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

  @override
  void initState() {
    super.initState();
    IosAnalytics.activate('start_trial');
  }

  @override
  void dispose() {
    IosAnalytics.left('start_trial');
    super.dispose();
  }

  Future<void> _buy() async {
    IosAnalytics.log('start_trial_continue_tapped', {'screen': 'start_trial', 'plan': 'yearly'});
    final s = S.of(context);
    setState(() => _busy = true);
    final ok = await buyPremium(context, yearly: true, screen: 'start_trial');
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
    IosAnalytics.log('restore_tap', {'screen': 'start_trial'});
    setState(() => _busy = true);
    final outcome = await AppScope.of(context).billing.restoreOutcome();
    IosAnalytics.restoreResult('start_trial', restored: outcome == RestoreOutcome.restored, reason: outcome.name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (outcome == RestoreOutcome.restored) {
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
    // activity_start_trial.xml on bg_trial ("Plum deck": #1F2933 → #0B1F1E)
    return NativeLightStatusBar(
      child: Scaffold(
        backgroundColor: const Color(0xFF1F2933),
        body: Stack(
          children: [
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
                          style: const TextStyle(color: Color(0xFF8FD6CB), fontSize: 30, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 40),
                        // timeline: bg_trial_line (24 dp, #4D8FD6CB → #148FD6CB, 12 dp corners) as tall as the steps
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
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Color(0x4D8FD6CB), Color(0x148FD6CB)],
                                    ),
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
                // bg_trial_card: #0F2A28 with a faint soft-teal hairline and 28 dp top corners
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F2A28),
                    border: Border.fromBorderSide(BorderSide(color: Color(0x1F8FD6CB))),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                                  prices.trialDays > 0 ? s.t('tryDaysFree', {'days': '${prices.trialDays}'}) : s.t('getPremium'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 6),
                              // bg_hot ("Plum deck"): the action teal, 8 dp corners, 16 dp tall
                              Container(
                                height: 16,
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                alignment: Alignment.center,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF0D8A7F),
                                  borderRadius: BorderRadius.all(Radius.circular(8)),
                                ),
                                child: Text(
                                  s.t('hot'),
                                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            s.t('tryThen', {'price': prices.yearly, 'perDay': prices.yearlyPerDay}),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFCCE7E3), fontSize: 12),
                          ),
                          if (Platform.isIOS) ...[
                            const SizedBox(height: 8),
                            Text(
                              s.t('iapAutoRenewInfo'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5, height: 1.35),
                            ),
                          ],
                          const SizedBox(height: 22),
                          PaywallContinueButton(
                            label: s.t('continueAction'),
                            colors: const [Color(0xFF14A394), Color(0xFF0D8A7F)],
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
              Text(body, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
