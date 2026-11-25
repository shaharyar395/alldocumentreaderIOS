import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show AppLifecycleListener, Brightness, Color, Colors, ThemeMode, WidgetsBinding;
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../core/settings/app_settings.dart';
import 'ad_remote_config.dart';
import 'in_app_messages.dart';
import 'ios_analytics.dart';
import 'ios_growth.dart';

class AdUnits {
  /// Documents Reader: Your DocsEra. These units are the iOS AdMob app only.
  static const appIdIos = 'ca-app-pub-9297250663056879~5342069314';
  static const _bannerIos = 'ca-app-pub-9297250663056879/4972027516';
  static const _banner2Ios = 'ca-app-pub-9297250663056879/4893890487';
  static const _appOpenIos = 'ca-app-pub-9297250663056879/7104286702';
  static const _interstitialIos = 'ca-app-pub-9297250663056879/3837415956';
  static const _nativeIos = 'ca-app-pub-9297250663056879/4958925933';

  /// Google's official iOS sample units. Not the Android sample units.
  static const iosSampleBanner = 'ca-app-pub-3940256099942544/2934735716';
  static const iosSampleInterstitial = 'ca-app-pub-3940256099942544/4411468910';
  static const iosSampleAppOpen = 'ca-app-pub-3940256099942544/5575463023';
  static const iosSampleNative = 'ca-app-pub-3940256099942544/3986624511';

  /// Debug builds may use Google's official iOS sample units.
  /// Release, TestFlight, and App Store builds always use this app's production units.
  static bool get useSample => kDebugMode;

  static String bannerFor(int unit) {
    if (useSample) return iosSampleBanner;
    return unit == 2 ? _banner2Ios : _bannerIos;
  }

  static String get banner => bannerFor(1);

  static String get appOpen => useSample ? iosSampleAppOpen : _appOpenIos;

  /// One production interstitial. Debug builds use the official iOS sample interstitial.
  static String get interstitial => useSample ? iosSampleInterstitial : _interstitialIos;

  static String get native => useSample ? iosSampleNative : _nativeIos;
}

class AdService {
  AdService(this.settings) {
    AdRemoteConfig.changes.addListener(_onRemoteConfig);
  }

  final AppSettings settings;
  bool ready = false;
  DateTime? _lastInterstitial;

  /// Shared with the file-type interstitial. Tools wait for this even when the ad is forced.
  /// The timer starts when the interstitial is dismissed, so the next ad waits the full
  /// Remote Config `file_type_ad_cooldown_sec` (default 30 seconds, clamped 0 … 86400).
  DateTime? _fileTypeShownAt;
  Duration get _fileTypeCooldown => Duration(seconds: AdRemoteConfig.fileTypeCooldownSec);

  bool get _fileTypeCooldownElapsed {
    final at = _fileTypeShownAt;
    if (at == null) return true;
    return DateTime.now().difference(at) >= _fileTypeCooldown;
  }
  AppOpenAd? _appOpen;
  DateTime? _appOpenAt;
  Future<AppOpenAd?>? _appOpenLoading;
  int _appOpenEpoch = 0;
  InterstitialAd? _interstitial;
  bool _interstitialLoading = false;
  int _interstitialEpoch = 0;
  bool _started = false;

  /// "Get Premium" after the category ad was already offered in this app run.
  bool premiumOfferedThisRun = false;

  /// Completes when the ads SDK has started (or could not start), so the launch ad can wait for it.
  final Completer<void> _startup = Completer<void>();

  /// Completes once the ads SDK has started (or could not start).
  Future<void> get started => _startup.future;

  /// Ads may be shown: SDK started, not Premium, and Remote Config `enable_ads` is on.
  bool get canShow => ready && !settings.premium && !kIsWeb && AdRemoteConfig.adsEnabled;

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

  void _opened() {
    _fullScreen = true;
    unawaited(InAppMessages.hold());
  }

  void _closed() {
    _fullScreen = false;
    _fullScreenClosed = DateTime.now();
    unawaited(InAppMessages.release());
  }

  Future<void> bootstrap() async {
    if (_started || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    // the App Open ad is the first one shown: start loading it as soon as the SDK is up
    unawaited(_startup.future.then((_) {
      if (canShow) _preloadAppOpen();
    }));
    try {
      // Google's order: the UMP consent form first, then (iOS) Apple's tracking question, then
      // the SDK
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          try {
            await ConsentForm.loadAndShowConsentFormIfRequired((_) {});
          } catch (error) {
            debugPrint('consent form: $error');
          }
          await _requestTracking();
          await _startAds();
        },
        (error) async {
          debugPrint('consent update: $error');
          await _requestTracking();
          await _startAds();
        },
      );
    } catch (error) {
      debugPrint('ads bootstrap: $error');
      if (!_startup.isCompleted) _startup.complete();
    }
  }

  /// iOS App Tracking Transparency, asked once, 400 ms after the app is in the foreground (iOS
  /// ignores the request while the app is not active). Not asked when the app does not become
  /// active within 30 s (asked again on the next launch).
  Future<void> _requestTracking() async {
    if (!Platform.isIOS) return;
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status != TrackingStatus.notDetermined) return;
      if (!await _whenActive(const Duration(seconds: 30))) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!await _whenActive(const Duration(seconds: 30))) return;
      IosAnalytics.log('att_permission_prompted', {'screen': 'home'});
      final decision = await AppTrackingTransparency.requestTrackingAuthorization();
      IosAnalytics.log('att_permission_result', {'result': decision.name, 'screen': 'home'});
    } catch (error) {
      debugPrint('tracking: $error');
    }
  }

  /// Waits (at most [limit]) until the app is in the foreground; false when it did not get there.
  Future<bool> _whenActive(Duration limit) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return true;
    final active = Completer<bool>();
    final listener = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed && !active.isCompleted) active.complete(true);
      },
    );
    try {
      return await active.future.timeout(limit, onTimeout: () => false);
    } finally {
      listener.dispose();
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

  /// After the loading screen (up to 12 s) and "Welcome back" (up to 8 s): the App Open ad.
  /// Waits for consent and for the ad to load, with one retry. If none loads, a ready interstitial
  /// is shown instead. The caller then shows the next screen with no fade, after it is visible.
  Future<void> showAppOpen({Duration wait = const Duration(seconds: 12)}) async {
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
        if (AdRemoteConfig.interstitialAds) {
          while (_interstitial == null && _interstitialLoading && left() > Duration.zero) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          if (_interstitial != null) await showInterstitial(force: true, untilClosed: true);
        }
        _preloadAppOpen();
        return;
      }
      final done = Completer<void>();
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdShowedFullScreenContent: (_) => IosAnalytics.log('app_open_ad_displayed'),
        onAdImpression: (_) => IosGrowth.adImpression(format: 'app_open'),
        onAdDismissedFullScreenContent: (ad) {
          IosAnalytics.log('app_open_ad_closed');
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

  /// Shows the ready interstitial. At most once every 45 seconds unless [force].
  /// [honorCooldown] still applies when the call is forced. The file-type timer starts when
  /// the ad is dismissed. [unit] is unused; one production interstitial is requested.
  Future<bool> showInterstitial({bool force = false, bool untilClosed = false, int unit = 1, bool honorCooldown = false}) async {
    if (!canShow || !AdRemoteConfig.interstitialAds || _fullScreen) return false;
    final last = _lastInterstitial;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 45)) {
      return false;
    }
    if (honorCooldown && !_fileTypeCooldownElapsed) return false;
    final ad = _interstitial;
    _interstitial = null;
    if (ad == null) {
      debugPrint('interstitial: none, continue');
      _preloadInterstitial();
      return false;
    }
    final closed = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        IosAnalytics.adShown('interstitial');
      },
      onAdImpression: (_) => IosGrowth.adImpression(format: 'interstitial'),
      onAdDismissedFullScreenContent: (ad) {
        final closedAt = DateTime.now();
        _lastInterstitial = closedAt;
        if (honorCooldown) _fileTypeShownAt = closedAt;
        IosAnalytics.adClosed('interstitial');
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

  /// A Remote Config value changed (Ads.applyRemoteConfig): drop what is now switched off or
  /// was loaded with the other kind of unit (real / demo), then load what is switched on.
  void _onRemoteConfig() {
    if (!AdRemoteConfig.adsEnabled) _dropLoadedAds();
    if (!AdRemoteConfig.interstitialAds) {
      _interstitialEpoch++;
      _interstitial?.dispose();
      _interstitial = null;
      _interstitialLoading = false;
    }
    if (!AdRemoteConfig.nativeAds) _dropNatives();
    if (!canShow) return;
    _preloadAppOpen();
    _preloadInterstitial();
    loadNativeAds();
  }

  /// Release, TestFlight, and App Store builds keep the production units when a load fails.
  bool noteLoadError(LoadAdError error) {
    debugPrint('ad load: ${error.message}');
    return false;
  }

  void _dropLoadedAds() {
    _appOpenEpoch++;
    _appOpen?.dispose();
    _appOpen = null;
    _appOpenAt = null;
    _appOpenLoading = null;
    _interstitialEpoch++;
    _interstitial?.dispose();
    _interstitial = null;
    _interstitialLoading = false;
    _dropNatives();
  }

  void _dropNatives() {
    _nativeEpoch++;
    final pending = _nativeDone;
    _nativeLoading = false;
    _nativeDone = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    for (final ad in _natives) {
      ad.dispose();
    }
    _natives.clear();
    _nativeAt = null;
  }

  // ------------------------------------------------------------------ native ads
  // Rows of the "Thank you for your support!" / Explore more apps sheet. Never for Premium.

  static const _nativeCount = 5;
  final List<NativeAd> _natives = [];
  bool _nativeLoading = false;
  int _nativeEpoch = 0;
  DateTime? _nativeAt;
  Completer<void>? _nativeDone;

  /// Loaded native ads (may be empty).
  List<NativeAd> get nativeAds => List.unmodifiable(_natives);

  bool get hasNativeAds => canShow && AdRemoteConfig.nativeAds && _natives.isNotEmpty;

  /// Loads up to [_nativeCount] native ads in the background (styled for the current theme).
  void loadNativeAds() {
    if (!canShow || !AdRemoteConfig.nativeAds || _nativeLoading) return;
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
    final epoch = _nativeEpoch;
    final sample = AdUnits.useSample;
    void finishOne(Ad ad) {
      if (epoch != _nativeEpoch) return;
      if (!settled.add(ad)) return;
      pending--;
      if (pending > 0) return;
      if (sample != AdUnits.useSample || !canShow || !AdRemoteConfig.nativeAds) {
        for (final loaded in fresh) {
          loaded.dispose();
        }
        fresh.clear();
      }
      for (final old in _natives) {
        old.dispose();
      }
      _natives
        ..clear()
        ..addAll(fresh);
      _nativeAt = fresh.isEmpty ? null : DateTime.now();
      _nativeLoading = false;
      if (!done.isCompleted) done.complete();
    }

    for (var i = 0; i < _nativeCount; i++) {
      final ad = NativeAd(
        adUnitId: AdUnits.native,
        request: const AdRequest(),
        nativeTemplateStyle: _nativeStyle(dark),
        listener: NativeAdListener(
          onAdImpression: (_) {
            IosGrowth.adImpression(format: 'native');
            IosAnalytics.adShown('native');
          },
          onPaidEvent: (ad, micros, precision, currency) {
            IosGrowth.adRevenue(micros / 1000000.0, currency);
          },
          onAdLoaded: (loaded) {
            if (epoch != _nativeEpoch || sample != AdUnits.useSample || !canShow || !AdRemoteConfig.nativeAds) {
              loaded.dispose();
              finishOne(loaded);
              return;
            }
            if (loaded is NativeAd) fresh.add(loaded);
            finishOne(loaded);
          },
          onAdFailedToLoad: (failed, error) {
            debugPrint('native: ${error.message}');
            failed.dispose();
            noteLoadError(error);
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
    if (!canShow || !AdRemoteConfig.nativeAds) return const [];
    if (_natives.isEmpty) loadNativeAds();
    final pending = _nativeDone;
    if (_nativeLoading && pending != null) {
      await pending.future.timeout(wait, onTimeout: () {});
    }
    return nativeAds;
  }

  /// One native ad for a conversion result. The caller destroys it when that screen closes.
  Future<NativeAd?> loadResultNative() async {
    if (!canShow || !AdRemoteConfig.nativeAds) return null;
    final done = Completer<NativeAd?>();
    final sample = AdUnits.useSample;
    late final NativeAd ad;
    ad = NativeAd(
      adUnitId: AdUnits.native,
      request: const AdRequest(),
      nativeTemplateStyle: NativeTemplateStyle(templateType: TemplateType.medium, cornerRadius: 12),
      listener: NativeAdListener(
        onAdLoaded: (loaded) {
          if (sample != AdUnits.useSample || !canShow || !AdRemoteConfig.nativeAds) {
            loaded.dispose();
            if (!done.isCompleted) done.complete(null);
            return;
          }
          if (!done.isCompleted) done.complete(loaded as NativeAd);
        },
        onAdFailedToLoad: (failed, error) {
          debugPrint('result native: ${error.message}');
          failed.dispose();
          noteLoadError(error);
          if (!done.isCompleted) done.complete(null);
        },
        onAdImpression: (_) {
          IosGrowth.adImpression(format: 'native');
          IosAnalytics.adShown('native');
        },
        onPaidEvent: (ad, micros, precision, currency) => IosGrowth.adRevenue(micros / 1000000.0, currency),
      ),
    );
    ad.load();
    return done.future.timeout(const Duration(seconds: 8), onTimeout: () {
      ad.dispose();
      return null;
    });
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
    final ink = dark ? const Color(0xFFE2E8F0) : const Color(0xFF1F2933);
    final muted = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return NativeTemplateStyle(
      templateType: TemplateType.small,
      mainBackgroundColor: dark ? const Color(0xFF162020) : Colors.white,
      cornerRadius: 12,
      callToActionTextStyle: NativeTemplateTextStyle(
        textColor: dark ? const Color(0xFF042F2E) : Colors.white,
        backgroundColor: dark ? const Color(0xFF45C4B4) : const Color(0xFF0F766E),
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
    final epoch = _appOpenEpoch;
    _appOpenLoading = _loadAppOpen().then((ad) {
      if (epoch != _appOpenEpoch) {
        ad?.dispose();
        return null;
      }
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
    final sample = AdUnits.useSample;
    final done = Completer<AppOpenAd?>();
    AppOpenAd.load(
      adUnitId: AdUnits.appOpen,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          if (sample != AdUnits.useSample || !canShow) {
            ad.dispose();
            if (!done.isCompleted) done.complete(null);
            return;
          }
          _notePaid(ad);
          if (!done.isCompleted) done.complete(ad);
        },
        onAdFailedToLoad: (error) {
          debugPrint('app open load: ${error.message}');
          noteLoadError(error);
          if (!done.isCompleted) done.complete(null);
        },
      ),
    );
    return done.future;
  }

  /// One production interstitial. Debug builds use the official iOS sample interstitial.
  void _preloadInterstitial() {
    if (!canShow || !AdRemoteConfig.interstitialAds || _interstitial != null || _interstitialLoading) return;
    _interstitialLoading = true;
    final epoch = _interstitialEpoch;
    final sample = AdUnits.useSample;
    final unit = AdUnits.interstitial;
    InterstitialAd.load(
      adUnitId: unit,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          if (epoch != _interstitialEpoch || sample != AdUnits.useSample || !canShow || !AdRemoteConfig.interstitialAds) {
            ad.dispose();
            return;
          }
          _interstitialLoading = false;
          _notePaid(ad);
          _interstitial?.dispose();
          _interstitial = ad;
        },
        onAdFailedToLoad: (error) {
          debugPrint('interstitial load: ${error.message}');
          if (epoch != _interstitialEpoch) return;
          _interstitialLoading = false;
          noteLoadError(error);
        },
      ),
    );
  }

  /// Rewarded and rewarded-interstitial units are not requested.
  Future<bool> showRewarded() async => false;

  void _notePaid(AdWithoutView ad) {
    ad.onPaidEvent = (ad, micros, precision, currency) {
      IosGrowth.adRevenue(micros / 1000000.0, currency);
    };
  }
}
