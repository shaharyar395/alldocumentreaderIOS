import 'dart:io';

import 'package:firebase_in_app_messaging/firebase_in_app_messaging.dart';
import 'package:flutter/foundation.dart';

/// Firebase In-App Messaging. Messages stay held on the splash screen and on an app-open ad,
/// because those screens close and take the message with them. A stable screen (language,
/// onboarding, or home) releases them and sends the app-open trigger again.
/// Automatic screen_view stays off, so a campaign that depends on screen_view will not fire.
class InAppMessages {
  InAppMessages._();

  static const _appOpen = 'ON_FOREGROUND';
  static var _held = false;
  static var _started = false;

  static Future<void> start() async {
    if (_started || kIsWeb || !Platform.isIOS || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    try {
      final fiam = FirebaseInAppMessaging.instance;
      await fiam.setAutomaticDataCollectionEnabled(true);
      await fiam.setMessagesSuppressed(true);
      _held = true;
    } catch (error) {
      debugPrint('in-app messages: $error');
    }
  }

  static Future<void> hold() async {
    if (!_started) return;
    _held = true;
    try {
      await FirebaseInAppMessaging.instance.setMessagesSuppressed(true);
    } catch (error) {
      debugPrint('in-app messages hold: $error');
    }
  }

  /// Language, onboarding, or home is on screen and will stay there.
  static Future<void> release() async {
    if (!_started) return;
    try {
      final fiam = FirebaseInAppMessaging.instance;
      await fiam.setMessagesSuppressed(false);
      if (!_held) return;
      _held = false;
      await fiam.triggerEvent(_appOpen);
    } catch (error) {
      debugPrint('in-app messages release: $error');
    }
  }
}
