import 'dart:async';
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, Color, Colors, ThemeMode, WidgetsBinding;
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/settings/app_settings.dart';

class AdUnits {
  static const testAppId = 'ca-app-pub-3940256099942544~3347511713';

  /// Documents Reader: Your DocsEra. These units are the iOS AdMob app only.
  static const appIdIos = 'ca-app-pub-9297250663056879~5342069314';
  static const _bannerIos = 'ca-app-pub-9297250663056879/4972027516';
  static const _banner2Ios = 'ca-app-pub-9297250663056879/4893890487';
  static const _appOpenIos = 'ca-app-pub-9297250663056879/8117065603';
  static const _interstitialIos = 'ca-app-pub-9297250663056879/3837415956';
  static const _interstitial2Ios = 'ca-app-pub-9297250663056879/5059657426';
  static const _nativeIos = 'ca-app-pub-9297250663056879/4958925933';
  static const _rewardedIos = 'ca-app-pub-9297250663056879/3746575754';
  static const _rewardedInterstitialIos = 'ca-app-pub-9297250663056879/2433494082';

  static const _testBanner = 'ca-app-pub-3940256099942544/9214589741';
  static const _testAppOpen = 'ca-app-pub-3940256099942544/9257395921';
  static const _testInterstitial = 'ca-app-pub-3940256099942544/1033173712';
  static const _testNative = 'ca-app-pub-3940256099942544/2247696110';
  static const _testRewarded = 'ca-app-pub-3940256099942544/5224354917';
  static const _testRewardedInterstitial = 'ca-app-pub-3940256099942544/5354046379';

  static String bannerFor(int unit) {
    if (!Platform.isIOS) return _testBanner;
    return unit == 2 ? _banner2Ios : _bannerIos;
  }

  static String get banner => bannerFor(1);

  static String get appOpen => Platform.isIOS ? _appOpenIos : _testAppOpen;

  static String interstitialFor(int unit) {
    if (!Platform.isIOS) return _testInterstitial;
    return unit == 2 ? _interstitial2Ios : _interstitialIos;
  }

  static String get interstitial => interstitialFor(1);

  static String get native => Platform.isIOS ? _nativeIos : _testNative;

  static String get rewarded => Platform.isIOS ? _rewardedIos : _testRewarded;

  static String get rewardedInterstitial => Platform.isIOS ? _rewardedInterstitialIos : _testRewardedInterstitial;
}

class AdService {
  AdService(this.settings);

  final AppSettings settings;
  bool ready = false;
  DateTime? _lastInterstitial;
  AppOpenAd? _appOpen;
  DateTime? _appOpenAt;
  Future<AppOpenAd?>? _appOpenLoading;
  final List<InterstitialAd?> _interstitials = [null, null, null];
  RewardedAd? _rewarded;
  bool _rewardedLoading = false;
  RewardedInterstitialAd? _rewardedInterstitial;
  bool _rewardedInterstitialLoading = false;
  DateTime? _interstitialPausedUntil;
  bool _started = false;

  /// "Get Premium" after the category ad was already offered in this app run.
  bool premiumOfferedThisRun = false;

  /// Completes when the ads SDK has started (or could not start), so the launch ad can wait for it.
  final Completer<void> _startup = Completer<void>();

  /// Completes once the ads SDK has started (or could not start).
  Future<void> get started => _startup.future;

  bool get canShow => ready && !settings.premium && !kIsWeb;

  /// A full-screen ad (App Open / interstitial) is on screen, or was closed a moment ago. The app
  /// counts as "in the background" while an ad shows, so "Welcome back" must not react to it
  /// (that would show Welcome back + another ad after every ad).
  bool _fullScreen = false;
  DateTime? _fullScreenClosed;

  bool get fullScreenActive {
    if (_fullScreen) return true;
    final closed = _fullScreenClosed;
    return closed != null && DateTime.now().difference(closed) < const Duration(seconds: 2);
  }

  void _opened() => _fullScreen = true;

  void _closed() {
    _fullScreen = false;
    _fullScreenClosed = DateTime.now();
  }

  Future<void> bootstrap() async {
    if (_started || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    // the App Open ad is the first one shown: start loading it as soon as the SDK is up
    unawaited(_startup.future.then((_) {
      if (canShow) _preloadAppOpen();
    }));
    try {
      if (Platform.isIOS) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final status = await AppTrackingTransparency.trackingAuthorizationStatus;
        if (status == TrackingStatus.notDetermined) {
          await AppTrackingTransparency.requestTrackingAuthorization();
        }
      }
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          try {
            await ConsentForm.loadAndShowConsentFormIfRequired((_) {});
          } catch (error) {
            debugPrint('consent form: $error');
          }
          await _startAds();
        },
        (error) {
          debugPrint('consent update: $error');
          _startAds();
        },
      );
    } catch (error) {
      debugPrint('ads bootstrap: $error');
      if (!_startup.isCompleted) _startup.complete();
    }
  }

  Future<void> _startAds() async {
    try {
      await MobileAds.instance.initialize();
      ready = true;
      _preloadAppOpen();
      _preloadInterstitial(1);
      _preloadInterstitial(2);
      _preloadRewarded();
      _preloadRewardedInterstitial();
      loadNativeAds();
    } catch (error) {
      debugPrint('ads init: $error');
    }
    if (!_startup.isCompleted) _startup.complete();
  }

  /// A loaded App Open ad that is still valid (Google: they expire after 4 hours).
  AppOpenAd? _takeAppOpen() {
    final ad = _appOpen;
    final at = _appOpenAt;
    _appOpen = null;
    _appOpenAt = null;
    if (ad != null && at != null && DateTime.now().difference(at) > const Duration(hours: 4)) {
      ad.dispose();
      return null;
    }
    return ad;
  }

  /// After the loading screen and "Welcome back": shows the App Open ad, like the Android app.
  /// Waits (at most [wait]) for the ads SDK to start (consent form included) and for the ad to
  /// load — only while it is still on its way; one retry when a request fails. If no App Open ad
  /// arrives, a ready full-screen ad is shown instead. Never waits for nothing (premium, offline).
  Future<void> showAppOpen({Duration wait = const Duration(seconds: 10)}) async {
    if (settings.premium || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    final deadline = DateTime.now().add(wait);
    Duration left() {
      final rest = deadline.difference(DateTime.now());
      return rest.isNegative ? Duration.zero : rest;
    }

    try {
      if (!ready) await _startup.future.timeout(left(), onTimeout: () {});
      if (!canShow) return;
      var ad = _takeAppOpen();
      for (var attempt = 0; ad == null && attempt < 2 && left() > Duration.zero; attempt++) {
        _preloadAppOpen();
        await _appOpenLoading?.timeout(left(), onTimeout: () => null);
        ad = _takeAppOpen();
      }
      if (ad == null) {
        debugPrint('app open: none loaded in time');
        if (_interstitials[1] != null) await showInterstitial(force: true);
        _preloadAppOpen();
        return;
      }
      final done = Completer<void>();
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) {
          _closed();
          ad.dispose();
          if (!done.isCompleted) done.complete();
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          debugPrint('app open show: $error');
          _closed();
          ad.dispose();
          if (!done.isCompleted) done.complete();
        },
      );
      _opened();
      await ad.show();
      await done.future.timeout(const Duration(minutes: 2), onTimeout: () {});
    } catch (error) {
      debugPrint('app open: $error');
      if (_fullScreen) _closed();
    }
    _preloadAppOpen();
  }

  /// Shows the ready full-screen ad (at most one a minute unless [force]). Returns whether an ad
  /// was shown. With [untilClosed] it returns only once the ad has been closed.
  Future<bool> showInterstitial({bool force = false, bool untilClosed = false, int unit = 1}) async {
    if (!canShow) return false;
    final paused = _interstitialPausedUntil;
    if (!force && paused != null && DateTime.now().isBefore(paused)) return false;
    final last = _lastInterstitial;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return false;
    }
    final slot = unit == 2 ? 2 : 1;
    final ad = _interstitials[slot];
    _interstitials[slot] = null;
    if (ad == null) {
      debugPrint('interstitial $slot: none, continue');
      _preloadInterstitial(slot);
      return false;
    }
    _lastInterstitial = DateTime.now();
    final closed = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        _closed();
        ad.dispose();
        if (!closed.isCompleted) closed.complete(true);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('interstitial show: $error');
        _closed();
        ad.dispose();
        if (!closed.isCompleted) closed.complete(false);
      },
    );
    _opened();
    try {
      await ad.show();
    } catch (error) {
      debugPrint('interstitial: $error');
      _closed();
      if (!closed.isCompleted) closed.complete(false);
    }
    _preloadInterstitial(unit == 2 ? 2 : 1);
    if (!untilClosed) return true;
    return closed.future.timeout(const Duration(minutes: 2), onTimeout: () => true);
  }

  // ------------------------------------------------------------------ native ads
  // Rows of the "Thank you for your support!" / Explore more apps sheet. Never for Premium.

  static const _nativeCount = 4;
  final List<NativeAd> _natives = [];
  bool _nativeLoading = false;
  DateTime? _nativeAt;
  Completer<void>? _nativeDone;

  /// Loaded native ads (may be empty).
  List<NativeAd> get nativeAds => List.unmodifiable(_natives);

  bool get hasNativeAds => canShow && _natives.isNotEmpty;

  /// Loads up to [_nativeCount] native ads in the background (styled for the current theme).
  void loadNativeAds() {
    if (!canShow || _nativeLoading) return;
    final at = _nativeAt;
    if (_natives.isNotEmpty && at != null && DateTime.now().difference(at) < const Duration(minutes: 50)) return;
    _nativeLoading = true;
    final done = Completer<void>();
    _nativeDone = done;
    final dark = switch (settings.themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
    };
    final fresh = <NativeAd>[];
    final settled = <Ad>{};
    var pending = _nativeCount;
    void finishOne(Ad ad) {
      if (!settled.add(ad)) return;
      pending--;
      if (pending > 0) return;
      for (final old in _natives) {
        old.dispose();
      }
      _natives
        ..clear()
        ..addAll(fresh);
      _nativeAt = DateTime.now();
      _nativeLoading = false;
      if (!done.isCompleted) done.complete();
    }

    for (var i = 0; i < _nativeCount; i++) {
      final ad = NativeAd(
        adUnitId: AdUnits.native,
        request: const AdRequest(),
        nativeTemplateStyle: _nativeStyle(dark),
        listener: NativeAdListener(
          onAdLoaded: (loaded) {
            if (loaded is NativeAd) fresh.add(loaded);
            finishOne(loaded);
          },
          onAdFailedToLoad: (failed, error) {
            debugPrint('native: ${error.message}');
            failed.dispose();
            finishOne(failed);
          },
        ),
      );
      ad.load().catchError((Object error) {
        debugPrint('native load: $error');
        finishOne(ad);
      });
    }
  }

  /// Waits (at most [wait]) for the native ads that are loading, then returns what is there.
  Future<List<NativeAd>> waitNativeAds({Duration wait = const Duration(seconds: 8)}) async {
    if (!canShow) return const [];
    if (_natives.isEmpty) loadNativeAds();
    final pending = _nativeDone;
    if (_nativeLoading && pending != null) {
      await pending.future.timeout(wait, onTimeout: () {});
    }
    return nativeAds;
  }

  /// After the sheet that showed them closed: native ads are used once, then fresh ones load.
  void releaseNativeAds() {
    for (final ad in _natives) {
      ad.dispose();
    }
    _natives.clear();
    _nativeAt = null;
    if (!_nativeLoading) loadNativeAds();
  }

  static NativeTemplateStyle _nativeStyle(bool dark) {
    final ink = dark ? const Color(0xFFF3F6FB) : const Color(0xFF1B2333);
    final muted = dark ? const Color(0xFF9AA6BA) : const Color(0xFF8B95A8);
    return NativeTemplateStyle(
      templateType: TemplateType.small,
      mainBackgroundColor: dark ? const Color(0xFF1B2230) : Colors.white,
      cornerRadius: 12,
      callToActionTextStyle: NativeTemplateTextStyle(
        textColor: Colors.white,
        backgroundColor: const Color(0xFF0A5FD9),
        style: NativeTemplateFontStyle.bold,
        size: 14,
      ),
      primaryTextStyle: NativeTemplateTextStyle(textColor: ink, style: NativeTemplateFontStyle.bold, size: 14),
      secondaryTextStyle: NativeTemplateTextStyle(textColor: muted, style: NativeTemplateFontStyle.normal, size: 12),
      tertiaryTextStyle: NativeTemplateTextStyle(textColor: muted, style: NativeTemplateFontStyle.normal, size: 12),
    );
  }

  /// Starts loading an App Open ad unless one is loaded (and fresh) or already loading.
  void _preloadAppOpen() {
    if (!canShow || _appOpenLoading != null) return;
    final at = _appOpenAt;
    if (_appOpen != null && at != null && DateTime.now().difference(at) < const Duration(hours: 4)) return;
    _appOpenLoading = _loadAppOpen().then((ad) {
      _appOpenLoading = null;
      if (ad != null) {
        _appOpen?.dispose();
        _appOpen = ad;
        _appOpenAt = DateTime.now();
      }
      return ad;
    });
  }

  Future<AppOpenAd?> _loadAppOpen() {
    final done = Completer<AppOpenAd?>();
    AppOpenAd.load(
      adUnitId: AdUnits.appOpen,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          if (!done.isCompleted) done.complete(ad);
        },
        onAdFailedToLoad: (error) {
          debugPrint('app open load: ${error.message}');
          if (!done.isCompleted) done.complete(null);
        },
      ),
    );
    return done.future;
  }

  void _preloadInterstitial(int unit) {
    final slot = unit == 2 ? 2 : 1;
    if (_interstitials[slot] != null) return;
    InterstitialAd.load(
      adUnitId: AdUnits.interstitialFor(slot),
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitials[slot]?.dispose();
          _interstitials[slot] = ad;
        },
        onAdFailedToLoad: (error) => debugPrint('interstitial $slot load: ${error.message}'),
      ),
    );
  }

  void _preloadRewarded() {
    if (!canShow || _rewarded != null || _rewardedLoading) return;
    _rewardedLoading = true;
    RewardedAd.load(
      adUnitId: AdUnits.rewarded,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedLoading = false;
          _rewarded?.dispose();
          _rewarded = ad;
        },
        onAdFailedToLoad: (error) {
          _rewardedLoading = false;
          debugPrint('rewarded load: ${error.message}');
        },
      ),
    );
  }

  /// Opt-in rewarded ad. True when the user earns the reward (one crowned template).
  Future<bool> showRewarded() async {
    if (!canShow) return false;
    final ad = _rewarded;
    _rewarded = null;
    if (ad == null) {
      _preloadRewarded();
      return false;
    }
    final earned = Completer<bool>();
    var got = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        _closed();
        ad.dispose();
        if (!earned.isCompleted) earned.complete(got);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('rewarded show: $error');
        _closed();
        ad.dispose();
        if (!earned.isCompleted) earned.complete(false);
      },
    );
    _opened();
    try {
      await ad.show(onUserEarnedReward: (ad, reward) => got = true);
    } catch (error) {
      debugPrint('rewarded: $error');
      _closed();
      if (!earned.isCompleted) earned.complete(false);
    }
    _preloadRewarded();
    return earned.future.timeout(const Duration(minutes: 2), onTimeout: () => got);
  }

  void _preloadRewardedInterstitial() {
    if (!canShow || _rewardedInterstitial != null || _rewardedInterstitialLoading) return;
    _rewardedInterstitialLoading = true;
    RewardedInterstitialAd.load(
      adUnitId: AdUnits.rewardedInterstitial,
      request: const AdRequest(),
      rewardedInterstitialAdLoadCallback: RewardedInterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedInterstitialLoading = false;
          _rewardedInterstitial?.dispose();
          _rewardedInterstitial = ad;
        },
        onAdFailedToLoad: (error) {
          _rewardedInterstitialLoading = false;
          debugPrint('rewarded interstitial load: ${error.message}');
        },
      ),
    );
  }

  /// Natural-transition rewarded interstitial. The reward skips the next interstitials for 15 minutes.
  /// Falls back to interstitial [unit] when this ad is not ready.
  Future<bool> showRewardedInterstitial({int unit = 2}) async {
    if (!canShow) return false;
    final ad = _rewardedInterstitial;
    _rewardedInterstitial = null;
    if (ad == null) {
      _preloadRewardedInterstitial();
      return showInterstitial(unit: unit);
    }
    final earned = Completer<bool>();
    var got = false;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        _closed();
        ad.dispose();
        if (!earned.isCompleted) earned.complete(got);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('rewarded interstitial show: $error');
        _closed();
        ad.dispose();
        if (!earned.isCompleted) earned.complete(false);
      },
    );
    _opened();
    try {
      await ad.show(onUserEarnedReward: (ad, reward) {
        got = true;
        _interstitialPausedUntil = DateTime.now().add(const Duration(minutes: 15));
      });
    } catch (error) {
      debugPrint('rewarded interstitial: $error');
      _closed();
      if (!earned.isCompleted) earned.complete(false);
    }
    _preloadRewardedInterstitial();
    return earned.future.timeout(const Duration(minutes: 2), onTimeout: () => got);
  }
}
