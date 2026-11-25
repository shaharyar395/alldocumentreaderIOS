import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';

/// Firebase Remote Config switches for ads — the same keys and defaults as the Android app
/// (ads/Ads.kt, 1.0.75). Until a published value arrives every switch keeps its default, so ads
/// stay on until the console turns them off. iOS reads its own Firebase project.
///
/// - `enable_ads` (true): every format, including app open and rewarded. False turns every ad off.
///   App open follows this switch, not the interstitial switch. The banner also follows `banner_ads`.
/// - `enable_test_ads` (false): kept for the console. It does not change which units are requested.
///   Every build requests this app's production units. A failed request stays on those units.
/// - `banner_ads` / `native_ads` / `interstitial_ads` (true): that format.
/// - `file_type_ad_cooldown_sec` (30): seconds between the All files file-type ads (0 … 86 400).
class AdRemoteConfig {
  AdRemoteConfig._();

  static const _enableAdsKey = 'enable_ads';
  static const _enableTestAdsKey = 'enable_test_ads';
  static const _bannerAdsKey = 'banner_ads';
  static const _nativeAdsKey = 'native_ads';
  static const _interstitialAdsKey = 'interstitial_ads';
  static const _fileTypeCooldownKey = 'file_type_ad_cooldown_sec';
  static const _defaultFileTypeCooldownSec = 30;

  static bool adsEnabled = true;
  static bool testAds = false;
  static bool bannerAds = true;
  static bool nativeAds = true;
  static bool interstitialAds = true;
  static int fileTypeCooldownSec = _defaultFileTypeCooldownSec;

  /// Bumped whenever a fetched value changed one of the switches (the ad service and the banner
  /// listen to it).
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static bool _started = false;

  /// Sets the defaults, applies what is cached, then fetches in the background (never blocks the
  /// launch). Firebase must be initialised already (IosGrowth.start).
  static Future<void> start() async {
    if (_started || kIsWeb || !Platform.isIOS || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    try {
      if (Firebase.apps.isEmpty) return;
      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(seconds: 10),
        minimumFetchInterval: const Duration(seconds: 60),
      ));
      await rc.setDefaults(const {
        _fileTypeCooldownKey: _defaultFileTypeCooldownSec,
        _enableAdsKey: true,
        _enableTestAdsKey: false,
        _bannerAdsKey: true,
        _nativeAdsKey: true,
        _interstitialAdsKey: true,
      });
      _apply(rc);
      rc.fetchAndActivate().then((_) => _apply(rc)).catchError((Object error) {
        debugPrint('remote config fetch: $error');
      });
    } catch (error) {
      debugPrint('remote config: $error');
    }
  }

  static void _apply(FirebaseRemoteConfig rc) {
    final before = (adsEnabled, testAds, bannerAds, nativeAds, interstitialAds, fileTypeCooldownSec);
    adsEnabled = rc.getBool(_enableAdsKey);
    testAds = rc.getBool(_enableTestAdsKey);
    bannerAds = rc.getBool(_bannerAdsKey);
    nativeAds = rc.getBool(_nativeAdsKey);
    interstitialAds = rc.getBool(_interstitialAdsKey);
    fileTypeCooldownSec = rc.getInt(_fileTypeCooldownKey).clamp(0, 86400);
    final after = (adsEnabled, testAds, bannerAds, nativeAds, interstitialAds, fileTypeCooldownSec);
    if (after != before) changes.value++;
  }
}
