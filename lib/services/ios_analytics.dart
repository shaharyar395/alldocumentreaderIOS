import 'dart:io';
import 'dart:math';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings/app_settings.dart';
import 'ios_growth.dart';

/// iOS Firebase Analytics. Automatic screen_view stays off. screen_view, select_content,
/// screen_open, open_screen, and tab_select are never sent. Event names are at most 40 characters.
class IosAnalytics {
  IosAnalytics._();

  static const _blocked = {'screen_view', 'select_content', 'screen_open', 'open_screen', 'tab_select'};

  static String currentScreen = 'splash';
  static String lastAction = 'none';
  static String? _reportedStatus;

  static String sanitize(String raw) {
    final cleaned = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    if (cleaned.length <= 40) return cleaned;
    return cleaned.substring(0, 40);
  }

  static bool get _on => !kIsWeb && Platform.isIOS && !Platform.environment.containsKey('FLUTTER_TEST') && IosGrowth.ready;

  static Future<void> bindUser(AppSettings settings) async {
    if (!_on) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('install_id') ?? '';
      if (id.isEmpty) {
        id = _uuid();
        await prefs.setString('install_id', id);
      }
      await FirebaseAnalytics.instance.setUserId(id: id);
      final status = settings.premium ? 'pro' : 'free';
      final plan = settings.premium ? (settings.subscriptionPlan == 'none' ? 'pro' : settings.subscriptionPlan) : 'none';
      await FirebaseAnalytics.instance.setUserProperty(name: 'user_type', value: status);
      await FirebaseAnalytics.instance.setUserProperty(name: 'subscription_status', value: status);
      await FirebaseAnalytics.instance.setUserProperty(name: 'subscription_plan', value: plan);
      await FirebaseAnalytics.instance.setUserProperty(name: 'login_method', value: 'none');
      await FirebaseAnalytics.instance.setUserProperty(name: 'account_status', value: 'none');
      final language = settings.languageSystem ? 'system' : settings.languageTag;
      await FirebaseAnalytics.instance.setUserProperty(name: 'app_language', value: language.length > 36 ? language.substring(0, 36) : language);
      if (_reportedStatus != status) {
        _reportedStatus = status;
        log('subscription_status', {'status': status, 'plan': plan});
      }
    } catch (error) {
      debugPrint('analytics user: $error');
    }
  }

  static void activate(String screen, [Map<String, Object> params = const {}]) {
    final name = sanitize(screen);
    if (name.isEmpty) return;
    currentScreen = name;
    log('${name}_screen_active', params);
  }

  static void left([String? screen]) {
    final name = sanitize(screen ?? currentScreen);
    if (name.isEmpty) return;
    log('${name}_screen_left');
  }

  static void back(String screen) {
    final name = sanitize(screen);
    log('${name}_back_tapped');
  }

  static void planSelected(String plan, String screen) {
    log('${plan}_plan_selected', {'plan': plan, 'screen': screen});
  }

  static void purchaseStart({required String plan, required String screen}) {
    log('purchase_start', {'plan': plan, 'screen': screen});
  }

  /// GA4 recommended `purchase`. The item id is the store product id. No purchase token.
  static void recommendedPurchase({required String itemId, required double value, required String currency}) {
    if (!_on) return;
    final id = itemId.length > 100 ? itemId.substring(0, 100) : itemId;
    final code = currency.trim().isEmpty ? 'USD' : currency.trim();
    FirebaseAnalytics.instance.logPurchase(
      currency: code.length > 100 ? code.substring(0, 100) : code,
      value: value,
      items: [AnalyticsEventItem(itemId: id)],
    ).catchError((Object error) {
      debugPrint('analytics purchase: $error');
    });
  }

  static void appError(String area, String reason) {
    log('app_error', {'area': area, 'reason': reason});
  }

  /// GA4 recommended `search`. The query is sent only on this event.
  static void searched(String term, int count) {
    if (!_on) return;
    final query = term.trim();
    if (query.isEmpty) return;
    final safe = query.length > 100 ? query.substring(0, 100) : query;
    FirebaseAnalytics.instance.logSearch(searchTerm: safe, parameters: {'result_count': '$count'}).catchError((Object error) {
      debugPrint('analytics search: $error');
    });
  }

  /// GA4 recommended `share`. Content type and count only.
  static void shared({required String contentType, required int count}) {
    if (!_on) return;
    final type = sanitize(contentType);
    FirebaseAnalytics.instance.logShare(
      contentType: type,
      itemId: type,
      method: 'system',
      parameters: {'count': '$count'},
    ).catchError((Object error) {
      debugPrint('analytics share: $error');
    });
  }

  static void adShown(String format) {
    if (format == 'app_open') {
      log('app_open_ad_displayed');
      return;
    }
    log('${format}_ad_displayed', {'ad_format': format});
  }

  static void adClosed(String format) {
    if (format == 'app_open') {
      log('app_open_ad_closed');
      return;
    }
    log('${format}_ad_closed', {'ad_format': format});
  }

  static void purchaseFinished({
    required String plan,
    required String screen,
    required String outcome,
    String? reason,
  }) {
    final why = (reason ?? '').replaceAll('\n', ' ').trim();
    final (event, result, fallback) = switch (outcome) {
      'success' => ('purchase_succeeded', 'success', 'success'),
      'canceled' => ('purchase_canceled', 'canceled', 'user_canceled'),
      'pending' => ('purchase_pending', 'pending', 'verification_pending'),
      _ => ('purchase_failed', 'failed', 'purchase_failed'),
    };
    final reported = why.isEmpty ? fallback : why;
    log(event, {'plan': plan, 'screen': screen, 'result': result, 'reason': reported.length > 100 ? reported.substring(0, 100) : reported});
  }

  static void converted(String from, String to) {
    log('${from}_converted_to_$to');
    log(to == 'word' ? 'word_file_saved' : '${to}_saved');
  }

  static void log(String event, [Map<String, Object> params = const {}]) {
    if (!_on) return;
    final name = sanitize(event);
    if (name.isEmpty || _blocked.contains(name)) return;
    final safe = <String, Object>{};
    params.forEach((key, value) {
      final k = sanitize(key);
      if (k.isEmpty) return;
      final text = value.toString();
      safe[k] = text.length > 100 ? text.substring(0, 100) : text;
    });
    FirebaseAnalytics.instance.logEvent(name: name, parameters: safe.isEmpty ? null : safe).catchError((Object error) {
      debugPrint('analytics $name: $error');
    });
    if (!name.startsWith('notification_') &&
        !name.startsWith('ad_') &&
        !name.startsWith('app_open_ad_') &&
        !name.endsWith('_screen_active') &&
        !name.endsWith('_screen_left') &&
        name != 'app_left') {
      lastAction = name;
    }
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// Logs [name] while this state is on screen, and the matching screen_left when it goes away.
mixin IosScreenTrack<T extends StatefulWidget> on State<T> {
  String get iosScreenName;
  Map<String, Object> get iosScreenParams => const {};
  bool _iosShown = false;

  void iosShowScreen() {
    if (_iosShown) return;
    _iosShown = true;
    IosAnalytics.activate(iosScreenName, iosScreenParams);
  }

  void iosLeaveScreen() {
    if (!_iosShown) return;
    _iosShown = false;
    IosAnalytics.left(iosScreenName);
  }

  @override
  void dispose() {
    iosLeaveScreen();
    super.dispose();
  }
}
