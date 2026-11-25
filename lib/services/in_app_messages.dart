import 'dart:io';

import 'package:firebase_in_app_messaging/firebase_in_app_messaging.dart';
import 'package:flutter/foundation.dart';

import 'platform_bridge.dart';

/// Firebase In-App Messaging.
///
/// Messages are never suppressed: suppression drops the campaign. Splash, Welcome back, and a
/// full-screen ad queue the message. It is shown on the first screen that stays open.
/// The native display listener stays registered across pauses so a message that arrives as the
/// app becomes active is not dropped. A button with no action URL dismisses the message.
class InAppMessages {
  InAppMessages._();

  static var _blocks = 0;
  static var _started = false;
  static var _sending = false;
  static var _again = false;

  static Future<void> _push() async {
    if (_sending) {
      _again = true;
      return;
    }
    _sending = true;
    try {
      do {
        _again = false;
        await PlatformBridge.fiamBlocked(_blocks > 0);
      } while (_again);
    } catch (error) {
      debugPrint('in-app messages: $error');
    } finally {
      _sending = false;
    }
    if (_again) {
      _again = false;
      await _push();
    }
  }

  static Future<void> start() async {
    if (_started || kIsWeb || !Platform.isIOS || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _started = true;
    try {
      final fiam = FirebaseInAppMessaging.instance;
      await fiam.setAutomaticDataCollectionEnabled(true);
      await fiam.setMessagesSuppressed(false);
      _blocks = 1;
      await _push();
    } catch (error) {
      debugPrint('in-app messages: $error');
    }
  }

  /// Splash, Welcome back, or a full-screen ad is covering the app.
  static Future<void> hold() async {
    if (!_started) return;
    _blocks++;
    await _push();
  }

  /// A stable screen is in front. A queued message is shown now.
  static Future<void> release() async {
    if (!_started) return;
    if (_blocks > 0) _blocks--;
    await _push();
  }
}
