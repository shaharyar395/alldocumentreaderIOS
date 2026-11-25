import 'dart:async';
import 'dart:io';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ios_analytics.dart';
import 'local_reminders.dart';
import 'platform_bridge.dart';

/// Firebase Cloud Messaging on iOS, like the Android app's push package (1.0.75):
/// - asks for notification permission once (the same prompt as the local reminders) and logs
///   notification_permission_requested / _granted / _denied;
/// - joins the "all_users" topic so a campaign from the Firebase console reaches every install;
/// - logs notification_received (app in front: iOS shows the banner too) and notification_opened
///   (tapped, also when the tap launched the app), with the Android parameters.
///
/// Needs in Xcode: Signing & Capabilities → + Push Notifications, and the APNs key uploaded in the
/// Firebase console (Project settings → Cloud Messaging → Apple app configuration). Without them
/// iOS gives no APNs token: the topic is not joined and no push arrives (nothing breaks).
class PushNotifications {
  PushNotifications._();

  static const topic = 'all_users';
  static const _openedKey = 'notif_last_open_id';
  static const _receivedKey = 'notif_received_ids';
  static bool _started = false;
  static String _version = '';

  static bool get _on => !kIsWeb && Platform.isIOS && !Platform.environment.containsKey('FLUTTER_TEST') && Firebase.apps.isNotEmpty;

  /// Called once a screen that stays open is up (where the reminders asked before).
  static Future<void> requestPermissionAndStart() async {
    if (!_on) {
      await LocalReminders.requestPermission();
      await LocalReminders.onRealOpen();
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      final before = await messaging.getNotificationSettings();
      final asking = before.authorizationStatus == AuthorizationStatus.notDetermined;
      if (asking) {
        _event('notification_permission_requested', type: 'firebase', category: 'permission', title: 'Notifications', id: 'permission', campaign: 'none', status: 'requested', action: 'requested');
      }
      // one system prompt for both: the local reminders' request (alert + sound)
      final grantedLocal = await LocalReminders.requestPermission(track: false);
      final after = await messaging.getNotificationSettings();
      final granted = grantedLocal ||
          after.authorizationStatus == AuthorizationStatus.authorized ||
          after.authorizationStatus == AuthorizationStatus.provisional;
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString('push_perm');
      final status = granted ? 'granted' : 'denied';
      if (previous != null && previous != status) {
        _event('notification_settings_changed', type: 'firebase', category: 'permission', title: 'Notifications', id: 'permission', campaign: 'none', status: status, action: status);
      }
      await prefs.setString('push_perm', status);
      if (asking && after.authorizationStatus != AuthorizationStatus.notDetermined) {
        _event(
          granted ? 'notification_permission_granted' : 'notification_permission_denied',
          type: 'firebase',
          category: 'permission',
          title: 'Notifications',
          id: 'permission',
          campaign: 'none',
          status: status,
          action: status,
        );
      }
      await _start(messaging);
      await LocalReminders.onRealOpen();
    } catch (error) {
      debugPrint('push: $error');
      _event('notification_delivery_failed', type: 'firebase', category: 'push', title: 'Notifications', id: 'setup', campaign: 'none', status: 'failed', action: 'none');
    }
  }

  static Future<void> _start(FirebaseMessaging messaging) async {
    if (_started) return;
    _started = true;
    _version = await PlatformBridge.appVersion() ?? '';
    // a push while the app is in front: show it like in the background
    await messaging.setForegroundNotificationPresentationOptions(alert: true, sound: true);
    FirebaseMessaging.onMessage.listen((message) async {
      if (!await _markOnce(_receivedKey, message)) return;
      _log('notification_received', message, status: 'received', action: 'none');
      // iOS shows this banner because foreground presentation is on. There is no separate display callback.
      _log('notification_displayed', message, status: 'displayed', action: 'none');
    });
    FirebaseMessaging.onMessageOpenedApp.listen(_opened);
    messaging.onTokenRefresh.listen((_) {
      unawaited(_subscribe(messaging));
    });
    final initial = await messaging.getInitialMessage();
    if (initial != null) await _opened(initial);
    unawaited(_subscribe(messaging));
  }

  /// A data message that woke the app. Notification banners are shown by iOS itself and do not
  /// arrive here. The same message id is recorded once.
  static Future<void> onBackgroundMessage(RemoteMessage message) async {
    if (!Platform.isIOS) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      if (!await _markOnce(_receivedKey, message)) return;
      final title = message.notification?.title ?? message.data['title']?.toString() ?? 'Document Reader';
      final id = message.messageId ?? 'firebase_${title.hashCode}';
      await FirebaseAnalytics.instance.logEvent(name: 'notification_received', parameters: {
        'notification_id': id.length > 100 ? id.substring(0, 100) : id,
        'notification_type': 'firebase',
        'notification_category': 'push',
        'notification_title': title.length > 100 ? title.substring(0, 100) : title,
        'notification_campaign': () {
          final campaign = message.data['campaign']?.toString() ?? 'none';
          return campaign.length > 100 ? campaign.substring(0, 100) : campaign;
        }(),
        'app_name': 'All Document Reader',
        'notification_timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
        'delivery_status': 'received',
        'user_action': 'none',
        'target_screen': LocalReminders.screenFor(message.data['screen']?.toString() ?? 'home'),
        'device_os': 'ios',
        'app_version': '',
      });
    } catch (error) {
      debugPrint('push background: $error');
    }
  }

  static Future<bool> _markOnce(String key, RemoteMessage message) async {
    final id = message.messageId ?? '';
    if (id.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(key) ?? const <String>[];
    if (seen.contains(id)) return false;
    final next = [...seen, id];
    await prefs.setStringList(key, next.length > 30 ? next.sublist(next.length - 30) : next);
    return true;
  }

  /// iOS needs the APNs token before a topic can be joined; it can arrive a little later.
  static Future<void> _subscribe(FirebaseMessaging messaging) async {
    final settings = await messaging.getNotificationSettings();
    final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!allowed) return;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final apns = await messaging.getAPNSToken();
        if (apns != null) {
          await messaging.subscribeToTopic(topic);
          return;
        }
      } catch (error) {
        debugPrint('push topic: $error');
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    debugPrint('push: no APNs token (Push Notifications capability / APNs key missing?)');
    _event(
      'notification_delivery_failed',
      type: 'firebase',
      category: 'push',
      title: 'Notifications',
      id: 'apns',
      campaign: 'none',
      status: 'failed',
      action: 'none',
    );
  }

  static Future<void> _opened(RemoteMessage message) async {
    final id = message.messageId ?? 'firebase_${_title(message).hashCode}';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_openedKey) == id) return;
    await prefs.setString(_openedKey, id);
    final screen = LocalReminders.screenFor(message.data['screen']?.toString() ?? 'home');
    _log('notification_opened', message, status: 'opened', action: 'open', screen: screen);
    LocalReminders.openRequest.value = screen;
  }

  static String _title(RemoteMessage message) => message.notification?.title ?? message.data['title']?.toString() ?? 'Document Reader';

  static void _log(String event, RemoteMessage message, {required String status, required String action, String screen = 'none'}) {
    final title = _title(message);
    _event(
      event,
      type: 'firebase',
      category: 'push',
      title: title,
      id: message.messageId ?? 'firebase_${title.hashCode}',
      campaign: message.data['campaign']?.toString() ?? 'none',
      status: status,
      action: action,
      screen: screen,
    );
  }

  /// NotificationEvents.send: the same parameter set as Android.
  static void _event(
    String event, {
    required String type,
    required String category,
    required String title,
    required String id,
    required String campaign,
    required String status,
    required String action,
    String screen = 'none',
  }) {
    IosAnalytics.log(event, {
      'notification_id': id,
      'notification_type': type,
      'notification_category': category,
      'notification_title': title,
      'notification_campaign': campaign.isEmpty ? 'none' : campaign,
      'app_name': 'All Document Reader',
      'notification_timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      'delivery_status': status,
      'user_action': action,
      'target_screen': screen,
      'device_os': 'ios_${Platform.operatingSystemVersion.split(' ').firstWhere((p) => RegExp(r'^\d').hasMatch(p), orElse: () => '')}',
      'app_version': _version,
    });
  }
}

/// Must stay a top-level function. iOS calls it in a separate isolate for data messages.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) {
  return PushNotifications.onBackgroundMessage(message);
}
