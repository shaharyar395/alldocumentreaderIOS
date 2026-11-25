import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/settings/app_settings.dart';
import 'apple_entitlement.dart';
import 'platform_bridge.dart';

/// iOS App Store subscription ids. The Android Google Play ids (yourdocs_premium_*) are never
/// sent to StoreKit.
abstract final class AppleProductIds {
  static const yearly = appleProductYearly;
  static const monthly = appleProductMonthly;
  static const all = [yearly, monthly];
}

/// One subscription as StoreKit 2 reports it (Apple's localized price, period, intro offer).
class ApplePlan {
  ApplePlan.fromMap(Map<Object?, Object?> m)
      : id = m['id'] as String? ?? '',
        displayPrice = m['displayPrice'] as String? ?? '',
        price = (m['price'] as num?)?.toDouble() ?? 0,
        currencyCode = m['currencyCode'] as String? ?? '',
        periodUnit = m['periodUnit'] as String?,
        periodValue = (m['periodValue'] as num?)?.toInt(),
        introMode = m['introMode'] as String?,
        introUnit = m['introUnit'] as String?,
        introValue = (m['introValue'] as num?)?.toInt(),
        introPeriodCount = (m['introPeriodCount'] as num?)?.toInt() ?? 1,
        introEligible = m['introEligible'] as bool?;

  final String id;
  final String displayPrice;
  final double price;
  final String currencyCode;
  final String? periodUnit;
  final int? periodValue;
  final String? introMode;
  final String? introUnit;
  final int? introValue;
  final int introPeriodCount;
  final bool? introEligible;

  /// Days of the free trial this Apple Account can still get (0 = none configured / used).
  int get freeTrialDays {
    if (introMode != 'freeTrial' || introEligible != true) return 0;
    final unit = switch (introUnit) { 'day' => 1, 'week' => 7, 'month' => 30, 'year' => 365, _ => 0 };
    return unit * (introValue ?? 0) * max(1, introPeriodCount);
  }
}

enum PurchaseOutcome { success, cancelled, pending, verifying, failed, unavailable }

enum RestoreOutcome { restored, none, cancelled, failed }

/// An empty StoreKit list means "no subscription" only when the store actually answered.
/// A failed App Store sync is not an answer: the account may simply not have been fetched.
bool emptyEntitlementsMeanNoSubscription(String? syncError) => syncError != 'failed';

class _StoreSnapshot {
  const _StoreSnapshot({required this.facts, required this.syncError, required this.storeAnswered});

  final List<StoreKitFact> facts;
  final String? syncError;
  final bool storeAnswered;
}

/// Apple In-App Purchase for the iOS app.
///
/// StoreKit 2 verifies transactions on the device. Premium follows that verified entitlement.
/// Firebase Cloud Functions are not part of purchase, restore, or Premium activation.
/// Firebase is still started here so Analytics, Crashlytics, and notifications can run.
class AppleBilling {
  AppleBilling(this.settings);

  final AppSettings settings;
  static const _channel = MethodChannel('com.theoccess.alldocreader/platform');

  ApplePlan? yearly;
  ApplePlan? monthly;

  /// Transactions being applied right now (duplicate Transaction.updates).
  final Set<String> _inFlight = {};

  /// One entitlement change at a time, so a refresh cannot clear a purchase that is still saving.
  Future<void> _tail = Future<void>.value();

  /// iOS only. Initializes Firebase for the rest of the app. Purchase does not read the result.
  static String? lastError;

  static String _planOf(String productId) {
    final id = productId.toLowerCase();
    if (id.contains('year')) return 'yearly';
    if (id.contains('month')) return 'monthly';
    return 'pro';
  }

  String _planFromFacts() {
    final yearly = this.yearly?.id ?? '';
    if (settings.subscriptionPlan == 'yearly' || settings.subscriptionPlan == 'monthly') return settings.subscriptionPlan;
    if (yearly.isNotEmpty) return _planOf(yearly);
    return 'pro';
  }

  static Future<void> initBackend() async {
    if (!Platform.isIOS || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      await FirebaseAppCheck.instance.activate(
        appleProvider: kDebugMode ? AppleProvider.debug : AppleProvider.appAttestWithDeviceCheckFallback,
      );
    } catch (error) {
      debugPrint('apple billing: Firebase not configured ($error)');
    }
  }

  /// Called from PlatformBridge when Transaction.updates reports a transaction.
  void onNativeEvent(Object? raw) {
    if (raw is! Map || raw['event'] != 'transaction') return;
    unawaited(_deliver(StoreKitFact.fromMap(Map<Object?, Object?>.from(raw))));
  }

  /// App start: products, the Apple Account's current entitlement, then unfinished transactions.
  Future<void> start() async {
    PlatformBridge.onIapTransaction = onNativeEvent;
    await loadProducts();
    await refreshEntitlement();
    await retryUnfinished();
  }

  /// Verified transactions StoreKit still holds unfinished are applied again.
  Future<void> retryUnfinished() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('iapAttach') ?? const [];
      for (final item in raw) {
        if (item is Map && item['event'] == 'transaction') {
          await _deliver(StoreKitFact.fromMap(Map<Object?, Object?>.from(item)));
        }
      }
    } catch (error) {
      debugPrint('apple billing attach: $error');
    }
  }

  Future<void> loadProducts() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('iapProducts', {'ids': AppleProductIds.all}) ?? const [];
      for (final item in raw) {
        if (item is! Map) continue;
        final plan = ApplePlan.fromMap(Map<Object?, Object?>.from(item));
        if (plan.id == AppleProductIds.yearly) yearly = plan;
        if (plan.id == AppleProductIds.monthly) monthly = plan;
      }
    } catch (error) {
      debugPrint('apple billing products: $error');
    }
  }

  /// Per-install random UUID passed as StoreKit's appAccountToken. It is not proof of ownership.
  String get _accountToken {
    var token = settings.appAccountToken;
    if (token.isEmpty) {
      final r = Random.secure();
      final b = List<int>.generate(16, (_) => r.nextInt(256));
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      token = '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
      unawaited(settings.setAppAccountToken(token));
    }
    return token;
  }

  Future<PurchaseOutcome> buy(ApplePlan plan) async {
    final Map<Object?, Object?> result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>('iapPurchase', {
            'id': plan.id,
            'appAccountToken': _accountToken,
          }) ??
          const {};
    } catch (error) {
      lastError = '$error';
      debugPrint('apple buy: $error');
      return PurchaseOutcome.failed;
    }
    final status = result['status'] as String?;
    switch (status) {
      case 'pending':
        return PurchaseOutcome.pending;
      case 'cancelled':
        return PurchaseOutcome.cancelled;
      case 'unavailable':
        return PurchaseOutcome.unavailable;
    }
    final fact = StoreKitFact.fromMap(result);
    return _serialized(() async {
      final effect = evaluatePurchase(
        status: status,
        fact: fact,
        now: DateTime.now().millisecondsSinceEpoch,
        allowXcode: kDebugMode,
      );
      if (effect.unavailable) return PurchaseOutcome.unavailable;
      if (fact.verified && fact.transactionId.isNotEmpty && (effect.grant || effect.finish)) {
        if (fact.productId.isNotEmpty && fact.productId != plan.id) {
          lastError = 'plan_not_changed';
          return PurchaseOutcome.failed;
        }
        try {
          await _applyFact(fact);
        } catch (error) {
          lastError = '$error';
          debugPrint('apple buy apply: $error');
          return PurchaseOutcome.failed;
        }
      }
      if (!effect.grant || !settings.premium) {
        lastError = result['reason'] as String? ?? status ?? 'purchase_failed';
        return PurchaseOutcome.failed;
      }
      if (effect.expiryMs > 0 && settings.premiumExpiryMs != effect.expiryMs && settings.premiumExpiryMs <= effect.expiryMs) {
        lastError = 'expiry_not_saved';
        return PurchaseOutcome.failed;
      }
      lastError = null;
      return PurchaseOutcome.success;
    });
  }

  /// Runs [action] after every entitlement change already in progress.
  /// A failure in an earlier change does not skip this one.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    final result = previous.catchError((Object _) {}).then((_) => action());
    result.whenComplete(() {
      if (!gate.isCompleted) gate.complete();
    });
    return result;
  }

  /// Applies one verified update (renewal, refund, Ask to Buy approval, unfinished transaction).
  Future<void> _deliver(StoreKitFact fact) {
    return _serialized(() async {
      try {
        await _applyFact(fact);
      } catch (error) {
        debugPrint('apple deliver: $error');
      }
    });
  }

  /// Saves the entitlement, then finishes. Caller must already hold [_serialized].
  Future<void> _applyFact(StoreKitFact fact) async {
    if (fact.transactionId.isEmpty) return;
    if (!_inFlight.add(fact.transactionId)) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final decision = evaluateFact(fact, now: now, allowXcode: kDebugMode);
      if (!fact.verified || (!decision.entitled && !decision.finish)) return;
      if (decision.entitled) {
        final expiry = persistableExpiry(
          grantedExpiryMs: decision.expiryMs,
          cachedExpiryMs: settings.premiumExpiryMs,
          now: now,
        );
        await settings.setStorePremium(entitled: true, expiryMs: expiry, plan: _planOf(fact.productId));
      } else {
        final snap = await _loadSnapshot(sync: false);
        if (snap != null && (snap.storeAnswered || snap.facts.isNotEmpty)) {
          await _applyResolution(_resolution(snap, now));
        } else {
          await _applyResolution(const PremiumResolution(entitled: false, expiryMs: 0, fromStore: true));
        }
      }
      if (decision.finish) {
        await _channel.invokeMethod<bool>('iapFinish', {'transactionId': fact.transactionId});
      }
    } finally {
      _inFlight.remove(fact.transactionId);
    }
  }

  PremiumResolution _resolution(_StoreSnapshot snap, int now) {
    return resolvePremium(
      storeAnswered: snap.storeAnswered,
      facts: snap.facts,
      cachedPremium: settings.premium,
      cachedExpiryMs: settings.premiumExpiryMs,
      now: now,
      allowXcode: kDebugMode,
    );
  }

  Future<void> _applyResolution(PremiumResolution resolution) async {
    if (resolution.entitled) {
      final expiry = persistableExpiry(
        grantedExpiryMs: resolution.expiryMs,
        cachedExpiryMs: settings.premiumExpiryMs,
        now: DateTime.now().millisecondsSinceEpoch,
      );
      await settings.setStorePremium(entitled: true, expiryMs: expiry, plan: _planFromFacts());
      return;
    }
    if (settings.testPremiumActive) return;
    await settings.setStorePremium(entitled: false, expiryMs: 0);
  }

  /// Launch / foreground check. No Apple ID prompt. A failed read keeps a cache whose end date
  /// is still ahead. A missing end date is not kept.
  Future<void> refreshEntitlement() {
    return _serialized(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final snap = await _loadSnapshot(sync: false);
      if (snap == null) {
        await _applyResolution(_resolution(
          const _StoreSnapshot(facts: [], syncError: 'failed', storeAnswered: false),
          now,
        ));
        return;
      }
      await _applyResolution(_resolution(snap, now));
    });
  }

  /// Restore Purchases. AppStore.sync() runs only here, because it can ask for the Apple ID.
  /// A failed read leaves a still-valid cache alone.
  Future<RestoreOutcome> restore() {
    return _serialized(() async {
      final snap = await _loadSnapshot(sync: true);
      if (snap == null) return RestoreOutcome.failed;
      if (snap.syncError == 'cancelled') return RestoreOutcome.cancelled;
      if (!snap.storeAnswered && snap.facts.isEmpty) return RestoreOutcome.failed;
      final resolution = _resolution(snap, DateTime.now().millisecondsSinceEpoch);
      await _applyResolution(resolution);
      if (!resolution.fromStore) return RestoreOutcome.failed;
      return resolution.entitled ? RestoreOutcome.restored : RestoreOutcome.none;
    });
  }

  Future<_StoreSnapshot?> _loadSnapshot({required bool sync}) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('iapEntitlements', {'sync': sync});
      if (raw == null) return null;
      final statuses = _factsOf(raw['statuses']);
      final current = _factsOf(raw['items'], current: true);
      final facts = combineStoreFacts(statuses: statuses, current: current);
      final syncError = raw['syncError'] as String?;
      final statusError = raw['statusError'] == true;
      return _StoreSnapshot(
        facts: facts,
        syncError: syncError,
        storeAnswered: storeKitAnswered(
          callFailed: false,
          syncError: syncError,
          statusError: statusError,
          hasFacts: facts.isNotEmpty,
        ),
      );
    } catch (error) {
      debugPrint('apple entitlements: $error');
      return null;
    }
  }

  List<StoreKitFact> _factsOf(Object? raw, {bool current = false}) {
    final list = raw as List<Object?>? ?? const [];
    return [
      for (final item in list)
        if (item is Map) StoreKitFact.fromMap(Map<Object?, Object?>.from(item), inCurrentEntitlements: current),
    ];
  }
}
