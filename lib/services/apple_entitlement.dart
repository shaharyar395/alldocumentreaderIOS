/// On-device StoreKit 2 entitlement rules for the iOS subscriptions.
///
/// StoreKit's `VerificationResult.verified` is the proof. A cached Premium flag is only a
/// display copy of the last verified result. These functions never call Firebase.
const appleBundleId = 'com.ol.documents.reader.docera.offline';
const appleProductYearly = 'yourdocs_ios_premium_yearly';
const appleProductMonthly = 'yourdocs_ios_premium_monthly';
const appleProductIds = {appleProductYearly, appleProductMonthly};

/// One transaction or subscription-status record reported by StoreKit.
class StoreKitFact {
  const StoreKitFact({
    required this.verified,
    required this.productId,
    this.bundleId = '',
    this.transactionId = '',
    this.revoked = false,
    this.upgraded = false,
    this.expiresMs = 0,
    this.graceExpiresMs = 0,
    this.state = '',
    this.inCurrentEntitlements = false,
    this.environment = '',
    this.willAutoRenew = true,
  });

  /// True only when Swift passed a StoreKit `.verified` transaction.
  final bool verified;
  final String productId;
  final String bundleId;
  final String transactionId;
  final bool revoked;
  final bool upgraded;

  /// Paid-period end from the transaction. May be in the past during a grace period.
  final int expiresMs;

  /// Grace-period end from verified renewal info. 0 when StoreKit did not send one.
  final int graceExpiresMs;

  /// `subscribed`, `inGracePeriod`, `inBillingRetryPeriod`, `expired`, `revoked`, or empty.
  final String state;

  /// The transaction was emitted by `Transaction.currentEntitlements`.
  final bool inCurrentEntitlements;

  /// `Production`, `Sandbox`, `Xcode`, or empty on iOS 15.
  final String environment;

  /// False after the user cancels auto-renew. The paid period still counts.
  final bool willAutoRenew;

  factory StoreKitFact.fromMap(Map<Object?, Object?> map, {bool inCurrentEntitlements = false}) {
    return StoreKitFact(
      verified: map['verified'] == true,
      productId: map['productId'] as String? ?? map['id'] as String? ?? '',
      bundleId: map['bundleId'] as String? ?? '',
      transactionId: map['transactionId'] as String? ?? '',
      revoked: map['revoked'] == true,
      upgraded: map['upgraded'] == true,
      expiresMs: (map['expiresMs'] as num?)?.toInt() ?? 0,
      graceExpiresMs: (map['graceExpiresMs'] as num?)?.toInt() ?? 0,
      state: map['state'] as String? ?? '',
      inCurrentEntitlements: inCurrentEntitlements || map['inCurrentEntitlements'] == true,
      environment: map['environment'] as String? ?? '',
      willAutoRenew: map['willAutoRenew'] is bool ? map['willAutoRenew'] as bool : true,
    );
  }
}

/// What one verified fact means for Premium.
class FactDecision {
  const FactDecision({required this.entitled, required this.finish, required this.expiryMs});

  final bool entitled;

  /// Finish this StoreKit transaction after the decision is saved. Never for unverified data.
  final bool finish;
  final int expiryMs;

  static const none = FactDecision(entitled: false, finish: false, expiryMs: 0);
}

/// The Premium value to store after a StoreKit read.
class PremiumResolution {
  const PremiumResolution({required this.entitled, required this.expiryMs, required this.fromStore});

  final bool entitled;

  /// Paid-period or grace-period end. 0 means this answer entitles the user now but has no
  /// end date, so it must not be kept while StoreKit cannot be read.
  final int expiryMs;

  /// False when the store could not be read and a still-valid cached end date was kept.
  final bool fromStore;
}

/// How a `Product.purchase()` status affects Premium.
class PurchaseEvaluation {
  const PurchaseEvaluation({
    required this.grant,
    required this.finish,
    required this.expiryMs,
    this.unavailable = false,
  });

  final bool grant;
  final bool finish;
  final int expiryMs;
  final bool unavailable;

  static const noChange = PurchaseEvaluation(grant: false, finish: false, expiryMs: 0);
}

FactDecision evaluateFact(StoreKitFact fact, {required int now, required bool allowXcode}) {
  if (!fact.verified) return FactDecision.none;
  final ours = appleProductIds.contains(fact.productId);
  final bundleOk = fact.bundleId.isEmpty || fact.bundleId == appleBundleId;
  if (!bundleOk || !ours) return FactDecision.none;
  final finish = fact.transactionId.isNotEmpty;
  if (fact.environment == 'Xcode' && !allowXcode) {
    return FactDecision(entitled: false, finish: finish, expiryMs: 0);
  }
  if (fact.revoked || fact.state == 'revoked' || fact.upgraded) {
    return FactDecision(entitled: false, finish: finish, expiryMs: 0);
  }
  if (fact.state == 'inBillingRetryPeriod' || fact.state == 'expired') {
    return FactDecision(entitled: false, finish: finish, expiryMs: 0);
  }
  if (fact.state == 'inGracePeriod') {
    if (fact.graceExpiresMs > 0 && fact.graceExpiresMs <= now) {
      return FactDecision(entitled: false, finish: finish, expiryMs: 0);
    }
    final expiry = fact.graceExpiresMs > now
        ? fact.graceExpiresMs
        : (fact.expiresMs > now ? fact.expiresMs : 0);
    return FactDecision(entitled: true, finish: finish, expiryMs: expiry);
  }
  if (fact.state == 'subscribed') {
    // Cancellation only clears willAutoRenew. Access lasts until the paid period ends.
    if (fact.expiresMs > 0 && fact.expiresMs <= now) {
      return FactDecision(entitled: false, finish: finish, expiryMs: 0);
    }
    return FactDecision(entitled: true, finish: finish, expiryMs: fact.expiresMs > now ? fact.expiresMs : 0);
  }
  if (fact.inCurrentEntitlements) {
    // Apple still lists this transaction. A paid date already in the past is grace without an
    // end we can store: entitled for this answer only, with no offline window.
    return FactDecision(entitled: true, finish: finish, expiryMs: fact.expiresMs > now ? fact.expiresMs : 0);
  }
  if (fact.expiresMs > now) {
    return FactDecision(entitled: true, finish: finish, expiryMs: fact.expiresMs);
  }
  // A verified record that is not a current entitlement and has no time left is not Premium.
  // First launch and a cleared install stay free until Restore or a real purchase.
  return FactDecision(entitled: false, finish: finish, expiryMs: 0);
}

/// Subscription status wins for a product when StoreKit returned it. Current entitlements fill
/// products that had no verified status (the status call can fail while the local store answers).
List<StoreKitFact> combineStoreFacts({
  required List<StoreKitFact> statuses,
  required List<StoreKitFact> current,
}) {
  if (statuses.isEmpty) return current;
  final covered = statuses.where((fact) => fact.verified).map((fact) => fact.productId).toSet();
  return [
    ...statuses,
    ...current.where((fact) => fact.verified && !covered.contains(fact.productId)),
  ];
}

/// Offline Premium survives only until a StoreKit end date that is still in the future.
/// A missing date (0) is not an unlimited subscription.
bool offlineCacheCovers(int cachedExpiryMs, int now) => cachedExpiryMs > now;

/// End date to save. A grant that has its own future end replaces the cache. A grant with no
/// end date keeps a cache that is still in the future, and otherwise saves nothing durable.
int persistableExpiry({required int grantedExpiryMs, required int cachedExpiryMs, required int now}) {
  if (grantedExpiryMs > now) return grantedExpiryMs;
  if (cachedExpiryMs > now) return cachedExpiryMs;
  return 0;
}

bool storeKitAnswered({
  required bool callFailed,
  required String? syncError,
  required bool statusError,
  required bool hasFacts,
}) {
  if (callFailed) return false;
  if (syncError == 'failed' && !hasFacts) return false;
  if (statusError && !hasFacts) return false;
  return true;
}

PremiumResolution resolvePremium({
  required bool storeAnswered,
  required List<StoreKitFact> facts,
  required bool cachedPremium,
  required int cachedExpiryMs,
  required int now,
  required bool allowXcode,
}) {
  final verified = [
    for (final fact in facts)
      if (fact.verified) evaluateFact(fact, now: now, allowXcode: allowXcode),
  ];
  final grants = verified.where((decision) => decision.entitled).toList();
  if (grants.isNotEmpty) {
    var expiry = 0;
    for (final grant in grants) {
      if (grant.expiryMs > expiry) expiry = grant.expiryMs;
    }
    return PremiumResolution(entitled: true, expiryMs: expiry, fromStore: true);
  }
  final unverifiedOnly = facts.isNotEmpty && verified.isEmpty;
  if (!storeAnswered || unverifiedOnly) {
    final cacheLive = cachedPremium && offlineCacheCovers(cachedExpiryMs, now);
    return PremiumResolution(
      entitled: cacheLive,
      expiryMs: cacheLive ? cachedExpiryMs : 0,
      fromStore: false,
    );
  }
  return const PremiumResolution(entitled: false, expiryMs: 0, fromStore: true);
}

PurchaseEvaluation evaluatePurchase({
  required String? status,
  required StoreKitFact? fact,
  required int now,
  required bool allowXcode,
}) {
  switch (status) {
    case 'cancelled':
    case 'pending':
    case 'failed':
      return PurchaseEvaluation.noChange;
    case 'unavailable':
      return const PurchaseEvaluation(grant: false, finish: false, expiryMs: 0, unavailable: true);
    case 'unverified':
      return PurchaseEvaluation.noChange;
    case 'success':
      if (fact == null || !fact.verified) return PurchaseEvaluation.noChange;
      final decision = evaluateFact(fact, now: now, allowXcode: allowXcode);
      return PurchaseEvaluation(
        grant: decision.entitled,
        finish: decision.finish,
        expiryMs: decision.entitled ? decision.expiryMs : 0,
      );
    default:
      return PurchaseEvaluation.noChange;
  }
}
