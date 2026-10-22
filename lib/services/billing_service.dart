import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/settings/app_settings.dart';

class ProductIds {
  static const _yearlyEnv = String.fromEnvironment('IAP_YEARLY');
  static const _monthlyEnv = String.fromEnvironment('IAP_MONTHLY');
  static const localYearly = '';
  static const localMonthly = '';

  static String get yearly => _yearlyEnv.isNotEmpty ? _yearlyEnv : (localYearly.isNotEmpty ? localYearly : 'premium_yearly');

  static String get monthly => _monthlyEnv.isNotEmpty ? _monthlyEnv : (localMonthly.isNotEmpty ? localMonthly : 'premium_monthly');
}

class BillingService {
  BillingService(this.settings);

  final AppSettings settings;
  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  Completer<PurchaseStatus>? _pending;
  ProductDetails? yearly;
  ProductDetails? monthly;

  /// Set while the launch check runs: an active subscription was reported.
  bool _foundActive = false;

  Future<void> start() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      _sub ??= _iap.purchaseStream.listen(_onPurchases, onError: (Object error) {
        debugPrint('billing stream: $error');
      });
      if (await _iap.isAvailable()) {
        final response = await _iap.queryProductDetails({ProductIds.yearly, ProductIds.monthly});
        for (final product in response.productDetails) {
          if (product.id == ProductIds.yearly) yearly = product;
          if (product.id == ProductIds.monthly) monthly = product;
        }
        await _recheck();
      }
    } catch (error) {
      debugPrint('billing start: $error');
    }
  }

  Future<bool> get storeAvailable async {
    try {
      return await _iap.isAvailable();
    } catch (error) {
      return false;
    }
  }

  /// Launch check (Android): Google Play reports the subscriptions that are active right now.
  /// When it reports none, Premium is switched off (it ran out or was cancelled) — ads come back.
  /// A running debug test subscription is kept. iOS is not asked here, because restoring there
  /// can show an Apple ID sign-in at launch.
  Future<void> _recheck() async {
    if (!Platform.isAndroid || !settings.premium) return;
    _foundActive = false;
    try {
      await _iap.restorePurchases();
    } catch (error) {
      debugPrint('billing recheck: $error');
      return;   // no answer (offline …): keep Premium as it is
    }
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!_foundActive && !settings.testPremiumActive) await settings.setPremium(false);
  }

  Future<PurchaseStatus> buy(ProductDetails product) async {
    _pending = Completer<PurchaseStatus>();
    try {
      final started = await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (!started) return PurchaseStatus.error;
      return await _pending!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => PurchaseStatus.error,
      );
    } catch (error) {
      debugPrint('buy: $error');
      return PurchaseStatus.error;
    }
  }

  Future<bool> restore() async {
    try {
      if (!await _iap.isAvailable()) return settings.premium;
      final before = settings.premium;
      await _iap.restorePurchases();
      await Future<void>.delayed(const Duration(seconds: 3));
      return settings.premium && !before ? true : settings.premium;
    } catch (error) {
      debugPrint('restore: $error');
      return false;
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      final active = purchase.status == PurchaseStatus.purchased || purchase.status == PurchaseStatus.restored;
      if (active && (purchase.productID == ProductIds.yearly || purchase.productID == ProductIds.monthly)) {
        _foundActive = true;
        await settings.setPremium(true, fromStore: true);
      }
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      final waiter = _pending;
      if (waiter != null && !waiter.isCompleted && purchase.status != PurchaseStatus.pending) {
        waiter.complete(purchase.status);
      }
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
