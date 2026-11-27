import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ios_growth.dart';

/// One interstitial and one rewarded ad, kept ready by the Mobile Ads preloader.
/// The buffer is 1: after an ad is shown, the SDK loads the next one.
class AdManager {
  AdManager._();

  static final AdManager instance = AdManager._();

  static const bufferSize = 1;

  /// Google's official interstitial test units.
  static String get interstitialId => Platform.isIOS
      ? 'ca-app-pub-3940256099942544/4411468910'
      : 'ca-app-pub-3940256099942544/1033173712';

  /// Google's official rewarded test units.
  static String get rewardedId => Platform.isIOS
      ? 'ca-app-pub-3940256099942544/1712485313'
      : 'ca-app-pub-3940256099942544/5224354917';

  bool _started = false;

  /// Starts the SDK, then the two preloaders. Safe to call again.
  Future<void> start() async {
    if (_started || kIsWeb) return;
    await MobileAds.instance.initialize();
    await InterstitialAdPreloader.start(
      preloadId: interstitialId,
      preloadConfiguration: PreloadConfiguration(
        adUnitId: interstitialId,
        bufferSize: bufferSize,
      ),
      callback: PreloadCallback(
        onAdFailedToPreload: (preloadId, error) {
          debugPrint('interstitial preload: ${error.message}');
        },
      ),
    );
    await RewardedAdPreloader.start(
      preloadId: rewardedId,
      preloadConfiguration: PreloadConfiguration(
        adUnitId: rewardedId,
        bufferSize: bufferSize,
      ),
      callback: PreloadCallback(
        onAdFailedToPreload: (preloadId, error) {
          debugPrint('rewarded preload: ${error.message}');
        },
      ),
    );
    _started = true;
  }

  Future<bool> hasInterstitial() => InterstitialAdPreloader.isAdAvailable(interstitialId);

  Future<bool> hasRewarded() => RewardedAdPreloader.isAdAvailable(rewardedId);

  /// Shows a preloaded interstitial. False when the buffer is empty or the ad cannot open.
  /// [onDismissed] and [onFailed] run later, after this future has returned.
  Future<bool> showInterstitial({
    void Function()? onShown,
    void Function()? onImpression,
    void Function()? onDismissed,
    void Function()? onFailed,
  }) async {
    if (!await hasInterstitial()) return false;
    final ad = await InterstitialAdPreloader.pollAd(interstitialId);
    if (ad == null) return false;
    var finished = false;
    void finish(void Function()? notify) {
      if (finished) return;
      finished = true;
      notify?.call();
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) => onShown?.call(),
      onAdImpression: (_) => onImpression?.call(),
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        finish(onDismissed);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('interstitial show: $error');
        ad.dispose();
        finish(onFailed);
      },
    );
    ad.onPaidEvent = (ad, micros, precision, currency) {
      IosGrowth.adRevenue(micros / 1000000.0, currency);
    };
    try {
      await ad.show();
      return true;
    } catch (error) {
      debugPrint('interstitial: $error');
      ad.dispose();
      finish(onFailed);
      return false;
    }
  }

  /// Shows a preloaded rewarded ad. True only after the reward is earned and the ad closes.
  Future<bool> showRewarded({void Function()? onImpression}) async {
    if (!await hasRewarded()) return false;
    final ad = await RewardedAdPreloader.pollAd(rewardedId);
    if (ad == null) return false;
    final closed = Completer<bool>();
    var earned = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdImpression: (_) => onImpression?.call(),
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        if (!closed.isCompleted) closed.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('rewarded show: $error');
        ad.dispose();
        if (!closed.isCompleted) closed.complete(false);
      },
    );
    ad.onPaidEvent = (ad, micros, precision, currency) {
      IosGrowth.adRevenue(micros / 1000000.0, currency);
    };
    try {
      await ad.show(onUserEarnedReward: (_, _) {
        earned = true;
      });
    } catch (error) {
      debugPrint('rewarded: $error');
      if (!closed.isCompleted) closed.complete(false);
    }
    return closed.future.timeout(const Duration(minutes: 2), onTimeout: () => false);
  }
}
