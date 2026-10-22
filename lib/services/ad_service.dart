import 'dart:async';
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, Color, Colors, ThemeMode, WidgetsBinding;
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/settings/app_settings.dart';

class AdUnits {
  static const testAppId = 'ca-app-pub-3940256099942544~3347511713';

  // Fill these, or pass --dart-define=ADMOB_BANNER_ANDROID=... (and the matching iOS / app-open / interstitial names).
  // The AdMob application id in AndroidManifest.xml and Info.plist stays the Google test app id until you replace it.
  static const localBannerAndroid = '';
  static const localBannerIos = '';
  static const localAppOpenAndroid = '';
  static const localAppOpenIos = '';
  static const localInterstitialAndroid = '';
  static const localInterstitialIos = '';
  static const localNativeAndroid = '';
  static const localNativeIos = '';

  static const _bannerAndroid = String.fromEnvironment('ADMOB_BANNER_ANDROID');
  static const _bannerIos = String.fromEnvironment('ADMOB_BANNER_IOS');
  static const _appOpenAndroid = String.fromEnvironment('ADMOB_APP_OPEN_ANDROID');
  static const _appOpenIos = String.fromEnvironment('ADMOB_APP_OPEN_IOS');
  static const _interstitialAndroid = String.fromEnvironment('ADMOB_INTERSTITIAL_ANDROID');
  static const _interstitialIos = String.fromEnvironment('ADMOB_INTERSTITIAL_IOS');
  static const _nativeAndroid = String.fromEnvironment('ADMOB_NATIVE_ANDROID');
  static const _nativeIos = String.fromEnvironment('ADMOB_NATIVE_IOS');

  static String get banner => Platform.isAndroid
      ? _pick(_bannerAndroid, localBannerAndroid, 'ca-app-pub-3940256099942544/9214589741')
      : _pick(_bannerIos, localBannerIos, 'ca-app-pub-3940256099942544/2435281174');

  static String get appOpen => Platform.isAndroid
      ? _pick(_appOpenAndroid, localAppOpenAndroid, 'ca-app-pub-3940256099942544/9257395921')
      : _pick(_appOpenIos, localAppOpenIos, 'ca-app-pub-3940256099942544/5575463023');

  static String get interstitial => Platform.isAndroid
      ? _pick(_interstitialAndroid, localInterstitialAndroid, 'ca-app-pub-3940256099942544/1033173712')
      : _pick(_interstitialIos, localInterstitialIos, 'ca-app-pub-3940256099942544/4411468910');

  static String get native => Platform.isAndroid
      ? _pick(_nativeAndroid, localNativeAndroid, 'ca-app-pub-3940256099942544/2247696110')
      : _pick(_nativeIos, localNativeIos, 'ca-app-pub-3940256099942544/3986624511');

  static String _pick(String fromEnv, String local, String test) {
    if (fromEnv.isNotEmpty) return fromEnv;
    if (local.isNotEmpty) return local;
    return test;
  }
}

class AdService {
  AdService(this.settings);

  final AppSettings settings;
  bool ready = false;
  DateTime? _lastInterstitial;
  AppOpenAd? _appOpen;
  DateTime? _appOpenAt;
  Future<AppOpenAd?>? _appOpenLoading;
  InterstitialAd? _interstitial;
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
      _preloadInterstitial();
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
        if (_interstitial != null) await showInterstitial(force: true);
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
  Future<bool> showInterstitial({bool force = false, bool untilClosed = false}) async {
    if (!canShow) return false;
    final last = _lastInterstitial;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return false;
    }
    final ad = _interstitial;
    _interstitial = null;
    if (ad == null) {
      debugPrint('interstitial: none, continue');
      _preloadInterstitial();
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
    _preloadInterstitial();
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

  void _preloadInterstitial() {
    InterstitialAd.load(
      adUnitId: AdUnits.interstitial,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => _interstitial = ad,
        onAdFailedToLoad: (error) => debugPrint('interstitial load: ${error.message}'),
      ),
    );
  }
}
