import 'package:alldocreader/services/apple_entitlement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const now = 1700000000000;
  const month = 30 * 24 * 60 * 60 * 1000;
  const year = 365 * 24 * 60 * 60 * 1000;

  StoreKitFact fact({
    bool verified = true,
    String productId = appleProductMonthly,
    String bundleId = appleBundleId,
    String transactionId = 'tx-1',
    bool revoked = false,
    bool upgraded = false,
    int expiresMs = now + month,
    int graceExpiresMs = 0,
    String state = '',
    bool inCurrentEntitlements = false,
    String environment = 'Sandbox',
    bool willAutoRenew = true,
  }) {
    return StoreKitFact(
      verified: verified,
      productId: productId,
      bundleId: bundleId,
      transactionId: transactionId,
      revoked: revoked,
      upgraded: upgraded,
      expiresMs: expiresMs,
      graceExpiresMs: graceExpiresMs,
      state: state,
      inCurrentEntitlements: inCurrentEntitlements,
      environment: environment,
      willAutoRenew: willAutoRenew,
    );
  }

  PurchaseEvaluation buy(String status, StoreKitFact? purchase, {bool allowXcode = false}) {
    return evaluatePurchase(status: status, fact: purchase, now: now, allowXcode: allowXcode);
  }

  PremiumResolution resolve(
    List<StoreKitFact> facts, {
    bool storeAnswered = true,
    bool cachedPremium = false,
    int cachedExpiryMs = 0,
    bool allowXcode = false,
  }) {
    return resolvePremium(
      storeAnswered: storeAnswered,
      facts: facts,
      cachedPremium: cachedPremium,
      cachedExpiryMs: cachedExpiryMs,
      now: now,
      allowXcode: allowXcode,
    );
  }

  test('monthly and yearly verified purchases grant the matching product', () {
    final monthly = buy('success', fact());
    final yearly = buy('success', fact(productId: appleProductYearly, expiresMs: now + year));
    expect(monthly.grant, isTrue);
    expect(monthly.finish, isTrue);
    expect(monthly.expiryMs, now + month);
    expect(yearly.grant, isTrue);
    expect(yearly.expiryMs, now + year);
  });

  test('a verified purchase activates Premium and an unverified purchase does not', () {
    expect(buy('success', fact(state: 'subscribed')).grant, isTrue);
    final forged = buy(
      'success',
      fact(verified: false, state: 'subscribed', expiresMs: now + year),
    );
    expect(forged.grant, isFalse);
    expect(forged.finish, isFalse);
    expect(buy('unverified', fact(verified: false)).grant, isFalse);
  });

  test('cancelled, pending, and failed purchases do not grant Premium', () {
    for (final status in ['cancelled', 'pending', 'failed']) {
      final effect = buy(status, fact());
      expect(effect.grant, isFalse, reason: status);
      expect(effect.finish, isFalse, reason: status);
    }
    expect(buy('unavailable', null).unavailable, isTrue);
    expect(buy('unavailable', null).grant, isFalse);
  });

  test('restore grants an active entitlement and clears a real empty answer', () {
    final restored = resolve([
      fact(productId: appleProductYearly, inCurrentEntitlements: true, expiresMs: now + year),
    ]);
    expect(restored.entitled, isTrue);
    expect(restored.fromStore, isTrue);
    final none = resolve(const []);
    expect(none.entitled, isFalse);
    expect(none.fromStore, isTrue);
  });

  test('an active subscription grants and an expired one removes Premium', () {
    expect(resolve([fact(state: 'subscribed')]).entitled, isTrue);
    final expired = resolve([
      fact(state: 'expired', expiresMs: now - month),
    ], cachedPremium: true, cachedExpiryMs: now + month);
    expect(expired.entitled, isFalse);
    expect(expired.fromStore, isTrue);
  });

  test('cancellation keeps Premium until the paid period ends', () {
    final stillPaid = resolve([
      fact(state: 'subscribed', willAutoRenew: false, expiresMs: now + month),
    ]);
    expect(stillPaid.entitled, isTrue);
    expect(stillPaid.expiryMs, now + month);
    final ended = resolve([
      fact(state: 'subscribed', willAutoRenew: false, expiresMs: now - 1),
    ]);
    expect(ended.entitled, isFalse);
  });

  test('a refund or revocation removes Premium even before expiry', () {
    expect(resolve([fact(revoked: true, expiresMs: now + month)]).entitled, isFalse);
    expect(resolve([fact(state: 'revoked', expiresMs: now + month)]).entitled, isFalse);
    expect(buy('success', fact(revoked: true)).grant, isFalse);
    expect(buy('success', fact(revoked: true)).finish, isTrue);
  });

  test('a renewal extends the verified expiry', () {
    final first = resolve([fact(state: 'subscribed', expiresMs: now + month)]);
    final renewed = resolve([fact(state: 'subscribed', transactionId: 'tx-2', expiresMs: now + 2 * month)]);
    expect(first.expiryMs, now + month);
    expect(renewed.entitled, isTrue);
    expect(renewed.expiryMs, now + 2 * month);
  });

  test('billing grace grants access and billing retry does not', () {
    final grace = resolve([
      fact(
        state: 'inGracePeriod',
        expiresMs: now - month,
        graceExpiresMs: now + 16 * 24 * 60 * 60 * 1000,
      ),
    ]);
    expect(grace.entitled, isTrue);
    expect(grace.expiryMs, now + 16 * 24 * 60 * 60 * 1000);
    expect(resolve([fact(state: 'inGracePeriod', graceExpiresMs: now - 1)]).entitled, isFalse);
    expect(resolve([fact(state: 'inBillingRetryPeriod', expiresMs: now + month)]).entitled, isFalse);
    final listedDuringGrace = resolve([
      fact(inCurrentEntitlements: true, expiresMs: now - month),
    ]);
    expect(listedDuringGrace.entitled, isTrue);
    expect(listedDuringGrace.expiryMs, 0);
    final noDate = resolve([
      fact(state: 'inGracePeriod', expiresMs: now - month, graceExpiresMs: 0),
    ]);
    expect(noDate.entitled, isTrue);
    expect(noDate.expiryMs, 0);
    expect(noDate.fromStore, isTrue);
  });

  test('app restart keeps an unexpired cache only when StoreKit does not answer', () {
    final offline = resolve(
      const [],
      storeAnswered: false,
      cachedPremium: true,
      cachedExpiryMs: now + month,
    );
    expect(offline.entitled, isTrue);
    expect(offline.fromStore, isFalse);
    final back = resolve([fact(state: 'subscribed', expiresMs: now + year)]);
    expect(back.entitled, isTrue);
    expect(back.fromStore, isTrue);
    final stale = resolve(const [], storeAnswered: false, cachedPremium: true, cachedExpiryMs: now - 1);
    expect(stale.entitled, isFalse);
  });

  test('reinstall follows current entitlements and does not invent Premium', () {
    final kept = resolve([
      fact(productId: appleProductYearly, inCurrentEntitlements: true, state: 'subscribed', expiresMs: now + year),
    ]);
    expect(kept.entitled, isTrue);
    expect(resolve(const []).entitled, isFalse);
    expect(resolve(const [], storeAnswered: false).entitled, isFalse);
  });

  test('offline startup does not create Premium and a store failure keeps a live cache', () {
    expect(resolve(const [], storeAnswered: false).entitled, isFalse);
    expect(
      storeKitAnswered(callFailed: true, syncError: null, statusError: false, hasFacts: false),
      isFalse,
    );
    expect(
      storeKitAnswered(callFailed: false, syncError: 'failed', statusError: false, hasFacts: false),
      isFalse,
    );
    final kept = resolve(
      const [],
      storeAnswered: false,
      cachedPremium: true,
      cachedExpiryMs: now + month,
    );
    expect(kept.entitled, isTrue);
    expect(kept.fromStore, isFalse);
  });

  test('transaction updates ignore duplicates, upgrades, and the wrong product or bundle', () {
    final duplicate = resolve([
      fact(transactionId: 'tx-9', state: 'subscribed'),
      fact(transactionId: 'tx-9', state: 'subscribed'),
    ]);
    expect(duplicate.entitled, isTrue);
    final changed = resolve([
      fact(productId: appleProductMonthly, upgraded: true, state: 'expired', expiresMs: now - 1),
      fact(productId: appleProductYearly, transactionId: 'tx-year', state: 'subscribed', expiresMs: now + year),
    ]);
    expect(changed.entitled, isTrue);
    expect(changed.expiryMs, now + year);
    expect(resolve([fact(productId: 'yourdocs_premium_monthly')]).entitled, isFalse);
    expect(resolve([fact(bundleId: 'com.example.other')]).entitled, isFalse);
    expect(buy('success', fact(productId: 'yourdocs_premium_yearly')).finish, isFalse);
  });

  test('status covers a product and current entitlements fill one without a status', () {
    final facts = combineStoreFacts(
      statuses: [fact(state: 'expired', expiresMs: now - 1)],
      current: [
        fact(inCurrentEntitlements: true, state: 'subscribed'),
        fact(productId: appleProductYearly, inCurrentEntitlements: true, expiresMs: now + year),
      ],
    );
    final resolution = resolve(facts);
    expect(resolution.entitled, isTrue);
    expect(resolution.expiryMs, now + year);
  });

  test('unverified facts do not grant and do not wipe a live cache', () {
    final kept = resolve(
      [fact(verified: false, state: 'subscribed', expiresMs: now + year)],
      cachedPremium: true,
      cachedExpiryMs: now + month,
    );
    expect(kept.entitled, isTrue);
    expect(kept.fromStore, isFalse);
  });

  test('Xcode StoreKit data is accepted only when local testing is allowed', () {
    final local = fact(environment: 'Xcode', state: 'subscribed');
    expect(buy('success', local).grant, isFalse);
    expect(buy('success', local, allowXcode: true).grant, isTrue);
  });

  test('a missing end date is not kept offline, and a real end date is', () {
    expect(
      resolve(const [], storeAnswered: false, cachedPremium: true, cachedExpiryMs: 0).entitled,
      isFalse,
    );
    final kept = resolve(
      const [],
      storeAnswered: false,
      cachedPremium: true,
      cachedExpiryMs: now + month,
    );
    expect(kept.entitled, isTrue);
    expect(kept.expiryMs, now + month);
    expect(
      persistableExpiry(grantedExpiryMs: 0, cachedExpiryMs: now + month, now: now),
      now + month,
    );
    expect(
      persistableExpiry(grantedExpiryMs: now + year, cachedExpiryMs: now + month, now: now),
      now + year,
    );
  });

  test('a verified expiry, revocation, or billing retry removes a cached Premium', () {
    for (final bad in [
      fact(state: 'expired', expiresMs: now - 1),
      fact(revoked: true, expiresMs: now + month),
      fact(state: 'inBillingRetryPeriod', expiresMs: now + month),
    ]) {
      final resolution = resolve([bad], cachedPremium: true, cachedExpiryMs: now + month);
      expect(resolution.entitled, isFalse, reason: bad.state + (bad.revoked ? ' revoked' : ''));
      expect(resolution.fromStore, isTrue);
    }
  });

  test('a network failure on purchase does not grant Premium', () {
    expect(buy('failed', null).grant, isFalse);
    expect(buy('failed', fact()).grant, isFalse);
  });
}
