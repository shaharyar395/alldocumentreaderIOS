import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../services/billing_service.dart';

/// Plan prices for the paywall, from the store — or the Android app's fallback texts when the
/// store returns nothing (debug builds, store not reachable).
class PlanPrices {
  const PlanPrices({
    required this.yearly,
    required this.yearlyPerDay,
    required this.monthly,
    required this.monthlyPerDay,
    required this.savePercent,
    required this.trialDays,
  });

  final String yearly;
  final String yearlyPerDay;
  final String monthly;
  final String monthlyPerDay;

  /// "Save N%" of the yearly plan against 12 months, or null when it can't be worked out.
  final int? savePercent;
  final int trialDays;

  static PlanPrices of(S s, BillingService billing) {
    final y = billing.yearly;
    final m = billing.monthly;
    int? save;
    if (y != null && m != null) {
      if (y.currencyCode == m.currencyCode && m.rawPrice > 0) {
        final percent = ((1 - y.rawPrice / (m.rawPrice * 12)) * 100).round();
        if (percent > 0) save = percent;
      }
    } else if (y == null && m == null) {
      save = 67; // matches the fallback prices below, like the Android app
    }
    return PlanPrices(
      yearly: y?.price ?? s.t('fallbackYearlyPrice'),
      yearlyPerDay: y == null ? s.t('fallbackYearlyPerDay') : _perDay(y, 365),
      monthly: m?.price ?? s.t('fallbackMonthlyPrice'),
      monthlyPerDay: m == null ? s.t('fallbackMonthlyPerDay') : _perDay(m, 30),
      savePercent: save,
      trialDays: 7,
    );
  }

  static String _perDay(ProductDetails product, int days) {
    return '${product.currencySymbol}${(product.rawPrice / days).toStringAsFixed(2)}';
  }
}

/// Opens the store's payment sheet for the yearly / monthly plan. Returns true when Premium is
/// on afterwards. Debug builds without a store offer the sandbox unlock (as before).
Future<bool> buyPremium(BuildContext context, {required bool yearly}) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  final billing = scope.billing;
  final product = yearly ? billing.yearly : billing.monthly;
  if (product == null) {
    final available = await billing.storeAvailable;
    if (!context.mounted) return false;
    if (!available && kDebugMode) {
      // like the Android debug TEST MODE sheet (sheet_test_purchase.xml): back / outside cancels
      final prices = PlanPrices.of(s, billing);
      final unlock = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (sheetContext) => _TestPurchaseSheet(
          product: 'All Document Reader Premium (${yearly ? s.t('yearly') : s.t('monthly')})',
          price: yearly
              ? '${s.t('planPriceYear', {'price': prices.yearly})} · ${s.t('planTrialDays', {'days': '${prices.trialDays}'})}'
              : s.t('planPriceMonth', {'price': prices.monthly}),
          title: s.t('sandboxTitle'),
          body: s.t('sandboxBody'),
          button: s.t('sandboxUnlock'),
        ),
      );
      if (unlock != true) return false;
      await scope.settings.setTestPremium(yearly: yearly);
      return true;
    }
    return false;
  }
  // the store's payment sheet is not "leaving the app": no Welcome back after it
  scope.guard.arm(scope.settings);
  final status = await billing.buy(product);
  return status == PurchaseStatus.purchased || status == PurchaseStatus.restored || scope.settings.premium;
}

/// Debug builds only: stand-in for the store's payment sheet (sheet_test_purchase.xml):
/// #202124 with 20dp top corners, "TEST MODE" badge, product, price, note, blue button.
class _TestPurchaseSheet extends StatelessWidget {
  const _TestPurchaseSheet({
    required this.product,
    required this.price,
    required this.title,
    required this.body,
    required this.button,
  });

  final String product;
  final String price;
  final String title;
  final String body;
  final String button;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF202124),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: const TextStyle(color: Color(0xFFE8EAED), fontSize: 17))),
                  Container(
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFB300),
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    child: const Text(
                      'TEST MODE',
                      style: TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(product, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(price, style: const TextStyle(color: Color(0xFFBDC1C6), fontSize: 16)),
              const SizedBox(height: 16),
              Text(body, style: const TextStyle(color: Color(0xFFBDC1C6), fontSize: 13, height: 1.32)),
              const SizedBox(height: 20),
              Material(
                color: const Color(0xFF8AB4F8),
                borderRadius: BorderRadius.circular(26),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.pop(context, true),
                  splashColor: const Color(0x33000000),
                  child: SizedBox(
                    height: 52,
                    child: Center(
                      child: Text(
                        button,
                        style: const TextStyle(color: Color(0xFF202124), fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
