import 'dart:io';

import 'package:adjust_sdk/adjust.dart';
import 'package:adjust_sdk/adjust_config.dart';
import 'package:adjust_sdk/adjust_event.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// iOS-only Firebase Analytics and Adjust. Android is left alone.
class IosGrowth {
  IosGrowth._();

  static const _adjustToken = 'namo63wquby8';
  static const _adRevenue = '61z020';
  static const _adImpression = 'b0hkyj';
  static const _startTrial = 'wzmgbk';

  static bool _ready = false;

  static bool get ready => _ready;

  static Future<void> start() async {
    if (_ready || !Platform.isIOS || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _ready = true;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      // The downloaded plist had collection off. Turn it on so these events are stored.
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(true);
    } catch (error) {
      debugPrint('firebase: $error');
    }
    try {
      final config = AdjustConfig(_adjustToken, AdjustEnvironment.production);
      config.attConsentWaitingInterval = 30;
      Adjust.initSdk(config);
    } catch (error) {
      debugPrint('adjust: $error');
    }
  }

  /// Adjust impression plus GA4 `ad_impression` named by [format] (banner, interstitial, app_open, native, rewarded).
  static void adImpression({String format = 'banner'}) {
    if (!_ready || !Platform.isIOS) return;
    try {
      Adjust.trackEvent(AdjustEvent(_adImpression));
    } catch (error) {
      debugPrint('adjust ad_impression: $error');
    }
    _firebase('ad_impression', {'ad_format': format});
  }

  static void adRevenue(double amount, String currency) {
    if (!_ready || !Platform.isIOS) return;
    final code = currency.isEmpty ? 'USD' : currency;
    try {
      final event = AdjustEvent(_adRevenue);
      event.setRevenue(amount, code);
      Adjust.trackEvent(event);
    } catch (error) {
      debugPrint('adjust revenue: $error');
    }
    _firebase('ad_revenue_adjust', {'value': amount, 'currency': code});
  }

  static void startTrial() => _event(_startTrial, 'start_trial');

  static void _event(String token, String name) {
    if (!_ready || !Platform.isIOS) return;
    try {
      Adjust.trackEvent(AdjustEvent(token));
    } catch (error) {
      debugPrint('adjust $name: $error');
    }
    _firebase(name);
  }

  static void _firebase(String name, [Map<String, Object> params = const {}]) {
    FirebaseAnalytics.instance.logEvent(name: name, parameters: params.isEmpty ? null : params).catchError((Object error) {
      debugPrint('firebase $name: $error');
    });
  }
}
