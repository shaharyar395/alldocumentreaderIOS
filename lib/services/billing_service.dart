import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../core/settings/app_settings.dart';
import 'apple_billing.dart';
import 'ios_growth.dart';

export 'apple_billing.dart' show PurchaseOutcome, RestoreOutcome;

/// Google Play subscription ids (Android only). iOS never sends these to StoreKit;
/// its App Store ids are [AppleProductIds].
class ProductIds {
  static const _yearlyEnv = String.fromEnvironment('IAP_YEARLY');
  static const _monthlyEnv = String.fromEnvironment('IAP_MONTHLY');
  static const localYearly = '';
  static const localMonthly = '';

  static String get yearly => _yearlyEnv.isNotEmpty ? _yearlyEnv : (localYearly.isNotEmpty ? localYearly : 'premium_yearly');

  static String get monthly => _monthlyEnv.isNotEmpty ? _monthlyEnv : (localMonthly.isNotEmpty ? localMonthly : 'premium_monthly');
}

/// A subscription plan as the paywall shows it, from either store.
class StorePlan {
  const StorePlan({
    required this.id,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    this.trialDays = 0,
    this.android,
    this.apple,
  });

  final String id;

  /// The store's localized price ("$29.99", "29,99 €").
  final String price;
  final double rawPrice;
  final String currencyCode;

  /// Free-trial days this account can get (iOS: from StoreKit's intro offer + eligibility).
  final int trialDays;
  final ProductDetails? android;
  final ApplePlan? apple;

  /// [value] in the format of [price] (same currency sign, decimal separator and position).
  String formatLike(double value) {
    final match = RegExp(r'\d[\d.,   ]*\d|\d').firstMatch(price);
    final fixed = value.toStringAsFixed(2);
    if (match == null) return '$currencyCode $fixed';
    final number = match.group(0)!;
    final comma = RegExp(r',\d{1,2}$').hasMatch(number);
    return price.replaceRange(match.start, match.end, comma ? fixed.replaceAll('.', ',') : fixed);
  }
}

class BillingService {
  BillingService(this.settings) : apple = AppleBilling(settings);

  final AppSettings settings;

  /// iOS: StoreKit 2 on device. Android: Google Play through [InAppPurchase].
  final AppleBilling apple;

  // lazy: never touched on iOS (StoreKit 1 there could finish a transaction before the entitlement is saved)
  late final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  Completer<PurchaseStatus>? _pending;
  ProductDetails? _androidYearly;
  ProductDetails? _androidMonthly;

  /// Set while the Android launch check runs: an active subscription was reported.
  bool _foundActive = false;

  StorePlan? get yearly => Platform.isIOS ? _fromApple(apple.yearly) : _fromAndroid(_androidYearly);
  StorePlan? get monthly => Platform.isIOS ? _fromApple(apple.monthly) : _fromAndroid(_androidMonthly);

  /// Free-trial days of the yearly plan: iOS = what StoreKit says this Apple Account can get
  /// (0 when no trial is configured or it was used); Android = Google Play decides at checkout.
  int get yearlyTrialDays => Platform.isIOS ? (apple.yearly?.freeTrialDays ?? 0) : 7;

  static StorePlan? _fromApple(ApplePlan? p) => p == null
      ? null
      : StorePlan(id: p.id, price: p.displayPrice, rawPrice: p.price, currencyCode: p.currencyCode, trialDays: p.freeTrialDays, apple: p);

  static StorePlan? _fromAndroid(ProductDetails? p) => p == null
      ? null
      : StorePlan(id: p.id, price: p.price, rawPrice: p.rawPrice, currencyCode: p.currencyCode, trialDays: 7, android: p);

  Future<void> start() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.isIOS) {
      await apple.start();
      return;
    }
    try {
      _sub ??= _iap.purchaseStream.listen(_onPurchases, onError: (Object error) {
        debugPrint('billing stream: $error');
      });
      if (await _iap.isAvailable()) {
        final response = await _iap.queryProductDetails({ProductIds.yearly, ProductIds.monthly});
        for (final product in response.productDetails) {
          if (product.id == ProductIds.yearly) _androidYearly = product;
          if (product.id == ProductIds.monthly) _androidMonthly = product;
        }
        await _recheck();
      }
    } catch (error) {
      debugPrint('billing start: $error');
    }
  }

  /// App back in the foreground: iOS drops an expired Premium, retries unfinished transactions,
  /// then re-checks the subscription with StoreKit.
  Future<void> onResume() async {
    if (!Platform.isIOS) return;
    await settings.expireStorePremiumIfPast();
    await apple.retryUnfinished();
    await apple.refreshEntitlement();
  }

  Future<bool> get storeAvailable async {
    if (Platform.isIOS) {
      if (apple.yearly == null && apple.monthly == null) await apple.loadProducts();
      return apple.yearly != null || apple.monthly != null;
    }
    try {
      return await _iap.isAvailable();
    } catch (error) {
      return false;
    }
  }

  /// Android launch check: Google Play reports the subscriptions that are active right now.
  Future<void> _recheck() async {
    if (!Platform.isAndroid || !settings.premium) return;
    _foundActive = false;
    try {
      await _iap.restorePurchases();
    } catch (error) {
      debugPrint('billing recheck: $error');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!_foundActive && !settings.testPremiumActive) await settings.setPremium(false);
  }

  Future<PurchaseOutcome> buy(StorePlan plan) async {
    final applePlan = plan.apple;
    if (Platform.isIOS) {
      final outcome = applePlan == null ? PurchaseOutcome.unavailable : await apple.buy(applePlan);
      if (outcome == PurchaseOutcome.success && plan.trialDays > 0 && plan.id == AppleProductIds.yearly) {
        IosGrowth.startTrial();
      }
      return outcome;
    }
    final product = plan.android;
    if (product == null) return PurchaseOutcome.unavailable;
    _pending = Completer<PurchaseStatus>();
    try {
      final started = await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: product));
      if (!started) return PurchaseOutcome.failed;
      final status = await _pending!.future.timeout(const Duration(minutes: 5), onTimeout: () => PurchaseStatus.error);
      return switch (status) {
        PurchaseStatus.purchased || PurchaseStatus.restored => PurchaseOutcome.success,
        PurchaseStatus.canceled => PurchaseOutcome.cancelled,
        PurchaseStatus.pending => PurchaseOutcome.pending,
        PurchaseStatus.error => PurchaseOutcome.failed,
      };
    } catch (error) {
      debugPrint('buy: $error');
      return PurchaseOutcome.failed;
    }
  }

  /// Restore Purchases. AppStore.sync() runs only here on iOS, because it can ask for the Apple ID.
  Future<RestoreOutcome> restoreOutcome() async {
    if (Platform.isIOS) return apple.restore();
    final ok = await restore();
    return ok ? RestoreOutcome.restored : RestoreOutcome.none;
  }

  Future<bool> restore() async {
    if (Platform.isIOS) {
      final outcome = await apple.restore();
      return outcome == RestoreOutcome.restored;
    }
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
        if (purchase.status == PurchaseStatus.purchased && purchase.productID == ProductIds.yearly) {
          IosGrowth.startTrial();
        }
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
