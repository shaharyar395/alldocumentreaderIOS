import 'dart:async';
import 'dart:io';

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
  static bool _started = false;
  static String _version = '';

  static bool get _on => !kIsWeb && Platform.isIOS && !Platform.environment.containsKey('FLUTTER_TEST') && Firebase.apps.isNotEmpty;

  /// Called once a screen that stays open is up (where the reminders asked before).
  static Future<void> requestPermissionAndStart() async {
    if (!_on) {
      await LocalReminders.requestPermission();
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      final before = await messaging.getNotificationSettings();
      final asking = before.authorizationStatus == AuthorizationStatus.notDetermined;
      if (asking) _event('notification_permission_requested', type: 'app', category: 'permission', title: 'Notifications', id: 'permission', campaign: 'none', status: 'requested', action: 'requested');
      // one system prompt for both: the local reminders' request (alert + sound)
      await LocalReminders.requestPermission();
      final after = await messaging.getNotificationSettings();
      final granted = after.authorizationStatus == AuthorizationStatus.authorized ||
          after.authorizationStatus == AuthorizationStatus.provisional;
      if (asking && after.authorizationStatus != AuthorizationStatus.notDetermined) {
        _event(
          granted ? 'notification_permission_granted' : 'notification_permission_denied',
          type: 'app',
          category: 'permission',
          title: 'Notifications',
          id: 'permission',
          campaign: 'none',
          status: granted ? 'granted' : 'denied',
          action: granted ? 'granted' : 'denied',
        );
      }
      await _start(messaging);
    } catch (error) {
      debugPrint('push: $error');
    }
  }

  static Future<void> _start(FirebaseMessaging messaging) async {
    if (_started) return;
    _started = true;
    _version = await PlatformBridge.appVersion() ?? '';
    // a push while the app is in front: show it like in the background
    await messaging.setForegroundNotificationPresentationOptions(alert: true, sound: true);
    FirebaseMessaging.onMessage.listen((message) => _log('notification_received', message, status: 'received', action: 'none'));
    FirebaseMessaging.onMessageOpenedApp.listen(_opened);
    final initial = await messaging.getInitialMessage();
    if (initial != null) await _opened(initial);
    unawaited(_subscribe(messaging));
  }

  /// iOS needs the APNs token before a topic can be joined; it can arrive a little later.
  static Future<void> _subscribe(FirebaseMessaging messaging) async {
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
  }

  static Future<void> _opened(RemoteMessage message) async {
    final id = message.messageId ?? 'firebase_${_title(message).hashCode}';
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_openedKey) == id) return;
    await prefs.setString(_openedKey, id);
    _log('notification_opened', message, status: 'opened', action: 'open', screen: 'splash');
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
