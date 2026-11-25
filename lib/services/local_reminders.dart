import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'ios_analytics.dart';
import 'platform_bridge.dart';

/// One local reminder. [at] is local time in milliseconds.
class ReminderPlan {
  const ReminderPlan(this.kind, this.at);

  final String kind;
  final int at;
}

/// Decides the next reminder. Pure so the caps can be checked without the OS.
class ReminderPlanner {
  static const gapMs = 8 * 60 * 60 * 1000;
  static const weekCap = 4;
  static const prodCap = 3;

  static const titles = {
    'welcome': 'Welcome back',
    'document': 'Document reminder',
    'reading': 'Reading reminder',
    'pdf': 'PDF conversion',
    'files': 'File management',
    'tools': 'Document tools',
    'productivity': 'Productivity reminder',
    'daily': 'Daily reminder',
  };

  static const bodies = {
    'welcome': 'Welcome back! Continue managing your documents with ease.',
    'document': 'Your documents are waiting. Open Document Reader and continue where you left off.',
    'reading': 'Continue reading your documents right where you left off.',
    'pdf': 'Convert your documents into PDF files in just a few taps.',
    'files': 'Keep your documents organized and easily accessible.',
    'tools': 'Explore useful tools to make document management easier.',
    'productivity': 'Make your documents easier to manage with Document Reader.',
    'daily': "Don't forget to organize your documents today.",
  };

  /// The next reminder after [now]. Nothing due right now is returned when [includeDue] is false.
  static ReminderPlan? next({
    required int now,
    required int open,
    required int sentAt,
    required int install,
    required int weekStart,
    required int weekCount,
    required int prodWeek,
    required int prodCount,
    required int readingOpen,
    required int documentOpen,
    required int welcomeOpen,
    required bool sentPdf,
    required bool sentFiles,
    required bool sentTools,
    bool includeDue = false,
  }) {
    var day = _dayStart(now);
    if (_openedOn(open, day)) day = _addDays(day, 1);
    for (var i = 0; i < 21; i++) {
      final plan = _choice(
        day: day,
        open: open,
        sentAt: sentAt,
        install: install,
        weekStart: weekStart,
        weekCount: weekCount,
        prodWeek: prodWeek,
        prodCount: prodCount,
        readingOpen: readingOpen,
        documentOpen: documentOpen,
        welcomeOpen: welcomeOpen,
        sentPdf: sentPdf,
        sentFiles: sentFiles,
        sentTools: sentTools,
      );
      if (plan != null && (plan.at > now || (includeDue && plan.at <= now))) return plan;
      day = _addDays(day, 1);
    }
    return null;
  }

  static ReminderPlan? _choice({
    required int day,
    required int open,
    required int sentAt,
    required int install,
    required int weekStart,
    required int weekCount,
    required int prodWeek,
    required int prodCount,
    required int readingOpen,
    required int documentOpen,
    required int welcomeOpen,
    required bool sentPdf,
    required bool sentFiles,
    required bool sentTools,
  }) {
    if (_openedOn(open, day)) return null;
    if (_count(weekStart, weekCount, day) >= weekCap) return null;
    final away = _daysBetween(open, day);
    final sinceInstall = _daysBetween(install, day);
    final String? kind;
    if (away >= 7) {
      kind = welcomeOpen == open ? null : 'welcome';
    } else if (away >= 4 && documentOpen != open) {
      kind = 'document';
    } else if (away >= 2 && away < 4 && readingOpen != open) {
      kind = 'reading';
    } else if (sinceInstall >= 3 && !sentPdf) {
      kind = 'pdf';
    } else if (sinceInstall >= 5 && !sentFiles) {
      kind = 'files';
    } else if (sinceInstall >= 7 && !sentTools) {
      kind = 'tools';
    } else if (_isProdDay(day) && _count(prodWeek, prodCount, day) < prodCap) {
      kind = 'productivity';
    } else {
      kind = _dailyOrNull(day, weekStart, weekCount);
    }
    if (kind == null) return null;
    final at = _at(day, _hour(kind));
    if (sentAt != 0 && at - sentAt < gapMs) return null;
    return ReminderPlan(kind, at);
  }

  static String? _dailyOrNull(int day, int weekStart, int weekCount) {
    final already = _count(weekStart, weekCount, day);
    if (already + 1 + _prodDaysAfter(day) > weekCap) return null;
    return 'daily';
  }

  static int _hour(String kind) => switch (kind) {
        'welcome' || 'reading' => 11,
        'document' => 18,
        'pdf' => 12,
        'files' => 17,
        'tools' => 13,
        'productivity' => 16,
        _ => 10,
      };

  static int _count(int weekStartStored, int count, int day) => _weekStart(day) == weekStartStored ? count : 0;

  static bool _openedOn(int open, int day) => open >= day && open < _addDays(day, 1);

  static bool _isProdDay(int day) {
    final d = DateTime.fromMillisecondsSinceEpoch(day).weekday;
    return d == DateTime.monday || d == DateTime.wednesday || d == DateTime.friday;
  }

  static int _prodDaysAfter(int day) {
    var n = 0;
    var cursor = day;
    final start = _weekStart(day);
    for (var i = 0; i < 6; i++) {
      cursor = _addDays(cursor, 1);
      if (_weekStart(cursor) != start) return n;
      if (_isProdDay(cursor)) n++;
    }
    return n;
  }

  static int _at(int day, int hour) {
    final d = DateTime.fromMillisecondsSinceEpoch(day);
    return DateTime(d.year, d.month, d.day, hour).millisecondsSinceEpoch;
  }

  static int _dayStart(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  }

  static int _addDays(int day, int days) {
    final d = DateTime.fromMillisecondsSinceEpoch(day);
    return DateTime(d.year, d.month, d.day + days).millisecondsSinceEpoch;
  }

  static int weekStartOf(int millis) => _weekStart(millis);

  static int _weekStart(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(_dayStart(millis));
    final back = (d.weekday + 6) % 7;
    return DateTime(d.year, d.month, d.day - back).millisecondsSinceEpoch;
  }

  static int _daysBetween(int earlier, int later) {
    var n = 0;
    var cursor = _dayStart(earlier);
    final end = _dayStart(later);
    while (cursor < end && n < 400) {
      cursor = _addDays(cursor, 1);
      n++;
    }
    return n;
  }
}

/// iOS local reminders. Nothing is shown at process start. A due reminder is left in place
/// when the user opens the app. No exact alarms.
class LocalReminders {
  LocalReminders._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static final openRequest = ValueNotifier<String?>(null);
  static var _ready = false;
  static var _zones = false;
  static var _launchHandled = false;
  static String _version = '';

  static String screenFor(String kind) => switch (kind) {
        'pdf' || 'tools' => 'tools',
        'settings' => 'settings',
        _ => 'home',
      };

  static Future<void> ensureReady() async {
    if (_ready || kIsWeb || !Platform.isIOS || Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (!_zones) {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.UTC);
      _zones = true;
    }
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(iOS: ios),
      onDidReceiveNotificationResponse: _onTapped,
    );
    _ready = true;
    final version = await PlatformBridge.appVersion();
    if (version != null) _version = version;
    if (_launchHandled) return;
    _launchHandled = true;
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final response = launch?.notificationResponse;
    if (launch?.didNotificationLaunchApp == true && response != null) _onTapped(response);
  }

  static void _onTapped(NotificationResponse response) {
    final kind = response.payload ?? '';
    if (kind.isEmpty) return;
    unawaited(_opened(kind, response.id ?? 0));
  }

  /// Ask only once a screen that stays open is up. Does not post a notification.
  /// [track] is false when Firebase push logs the same permission prompt.
  static Future<bool> requestPermission({bool track = true}) async {
    await ensureReady();
    if (!_ready) return false;
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final before = await ios?.checkPermissions();
    final asked = before?.isEnabled == true;
    if (track && !asked) {
      await _log(event: 'notification_permission_requested', kind: 'permission', id: 0, status: 'requested', action: 'requested');
    }
    final granted = await ios?.requestPermissions(alert: true, badge: false, sound: true) == true;
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString('local_perm');
    final status = granted ? 'granted' : 'denied';
    if (previous != null && previous != status) {
      await _log(event: 'notification_settings_changed', kind: 'permission', id: 0, status: status, action: status);
    }
    await prefs.setString('local_perm', status);
    if (track && !asked) {
      await _log(
        event: granted ? 'notification_permission_granted' : 'notification_permission_denied',
        kind: 'permission',
        id: 0,
        status: status,
        action: status,
      );
    }
    if (!granted) await _cancelStored(prefs);
    return granted;
  }

  /// A person brought the app forward. Not used for a notification delivery or a background launch.
  static Future<void> onRealOpen() async {
    await ensureReady();
    if (!_ready) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = await _alertsEnabled();
    final previous = prefs.getString('local_perm');
    if (!enabled) {
      // Never asked yet: don't mark it denied, and don't schedule.
      if (previous == 'granted') {
        await _log(event: 'notification_settings_changed', kind: 'permission', id: 0, status: 'denied', action: 'denied');
        await prefs.setString('local_perm', 'denied');
        await _cancelStored(prefs);
      }
      return;
    }
    if (previous != null && previous != 'granted') {
      await _log(event: 'notification_settings_changed', kind: 'permission', id: 0, status: 'granted', action: 'granted');
    }
    if (previous != 'granted') await prefs.setString('local_perm', 'granted');
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt('local_last_open_at', now);
    if (prefs.getInt('local_install_at') == null) await prefs.setInt('local_install_at', now);
    final before = prefs.getStringList('local_plan') ?? const <String>[];
    await _absorbDue(prefs, now);
    await _scheduleAhead(prefs, now);
    await _logPlanDiff(before, prefs.getStringList('local_plan') ?? const <String>[]);
  }

  static Future<bool> _alertsEnabled() async {
    final options = await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.checkPermissions();
    return options?.isEnabled == true;
  }

  static Future<void> _cancelStored(SharedPreferences prefs) async {
    final stored = prefs.getStringList('local_plan') ?? const <String>[];
    if (stored.isEmpty) return;
    for (final row in stored) {
      final parsed = _parse(row);
      if (parsed == null) continue;
      await _plugin.cancel(parsed.$1);
    }
    await prefs.setStringList('local_plan', const <String>[]);
    await _logPlanDiff(stored, const <String>[]);
  }

  static (int, String, int)? _parse(String row) {
    final parts = row.split('|');
    if (parts.length != 3) return null;
    final id = int.tryParse(parts[0]);
    final at = int.tryParse(parts[2]);
    if (id == null || at == null) return null;
    return (id, parts[1], at);
  }

  static String _keyOf(String row) {
    final parsed = _parse(row);
    if (parsed == null) return row;
    return '${parsed.$2}|${parsed.$3}';
  }

  static Future<void> _logPlanDiff(List<String> before, List<String> after) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final oldKeys = {for (final row in before) _keyOf(row)};
    final newKeys = {for (final row in after) _keyOf(row)};
    for (final row in before) {
      final parsed = _parse(row);
      // A reminder that is already due was shown, not cancelled.
      if (parsed == null || parsed.$3 <= now || newKeys.contains(_keyOf(row))) continue;
      await _log(event: 'notification_cancelled', kind: parsed.$2, id: parsed.$1, status: 'cancelled', action: 'cancelled', at: parsed.$3);
    }
    for (final row in after) {
      final parsed = _parse(row);
      if (parsed == null || oldKeys.contains(_keyOf(row))) continue;
      await _log(event: 'notification_scheduled', kind: parsed.$2, id: parsed.$1, status: 'scheduled', action: 'none', at: parsed.$3);
    }
  }

  static Future<void> _opened(String kind, int id) async {
    final prefs = await SharedPreferences.getInstance();
    final token = '$id|$kind';
    if (prefs.getString('local_last_open_token') == token) {
      openRequest.value = screenFor(kind);
      return;
    }
    await prefs.setString('local_last_open_token', token);
    await _log(event: 'notification_opened', kind: kind, id: id, status: 'opened', action: 'open');
    openRequest.value = screenFor(kind);
  }

  static Future<void> _log({
    required String event,
    required String kind,
    required int id,
    required String status,
    required String action,
    int? at,
  }) async {
    final title = ReminderPlanner.titles[kind] ?? 'Document Reader';
    IosAnalytics.log(event, {
      'notification_id': id == 0 ? kind : '$id',
      'notification_type': 'local',
      'notification_category': kind,
      'notification_title': title,
      'notification_campaign': 'local',
      'app_name': 'All Document Reader',
      'notification_timestamp': '${at ?? DateTime.now().millisecondsSinceEpoch}',
      'delivery_status': status,
      'user_action': action,
      'target_screen': screenFor(kind),
      'device_os': 'ios',
      'app_version': _version,
    });
  }

  /// A reminder that is already due stays on the notification list. Only future ones are rebuilt.
  static Future<void> _absorbDue(SharedPreferences prefs, int now) async {
    final stored = prefs.getStringList('local_plan') ?? const <String>[];
    final keep = <String>[];
    for (final row in stored) {
      final parts = row.split('|');
      if (parts.length != 3) continue;
      final at = int.tryParse(parts[2]) ?? 0;
      if (at > now + 120000) {
        await _plugin.cancel(int.tryParse(parts[0]) ?? 41001);
        continue;
      }
      if (at <= now) {
        await _record(prefs, parts[1], at);
        continue;
      }
      keep.add(row);
    }
    await prefs.setStringList('local_plan', keep);
  }

  static Future<void> _scheduleAhead(SharedPreferences prefs, int now) async {
    var sentAt = prefs.getInt('local_last_sent_at') ?? 0;
    var weekStart = prefs.getInt('local_week_start') ?? 0;
    var weekCount = prefs.getInt('local_week_count') ?? 0;
    var prodWeek = prefs.getInt('local_prod_week_start') ?? 0;
    var prodCount = prefs.getInt('local_prod_count') ?? 0;
    var readingOpen = prefs.getInt('local_sent_reading_open') ?? -1;
    var documentOpen = prefs.getInt('local_sent_document_open') ?? -1;
    var welcomeOpen = prefs.getInt('local_sent_welcome_open') ?? -1;
    var sentPdf = prefs.getBool('local_sent_pdf') ?? false;
    var sentFiles = prefs.getBool('local_sent_files') ?? false;
    var sentTools = prefs.getBool('local_sent_tools') ?? false;
    final open = prefs.getInt('local_last_open_at') ?? now;
    final install = prefs.getInt('local_install_at') ?? now;
    final kept = prefs.getStringList('local_plan') ?? const <String>[];
    final rows = <String>[...kept];
    var cursor = now;
    for (var i = 0; i < 8 && rows.length < 8; i++) {
      final plan = ReminderPlanner.next(
        now: cursor,
        open: open,
        sentAt: sentAt,
        install: install,
        weekStart: weekStart,
        weekCount: weekCount,
        prodWeek: prodWeek,
        prodCount: prodCount,
        readingOpen: readingOpen,
        documentOpen: documentOpen,
        welcomeOpen: welcomeOpen,
        sentPdf: sentPdf,
        sentFiles: sentFiles,
        sentTools: sentTools,
      );
      if (plan == null) break;
      cursor = plan.at + 1000;
      sentAt = plan.at;
      final week = ReminderPlanner.weekStartOf(plan.at);
      if (week == weekStart) {
        weekCount += 1;
      } else {
        weekStart = week;
        weekCount = 1;
      }
      if (plan.kind == 'productivity') {
        if (week == prodWeek) {
          prodCount += 1;
        } else {
          prodWeek = week;
          prodCount = 1;
        }
      }
      switch (plan.kind) {
        case 'reading':
          readingOpen = open;
        case 'document':
          documentOpen = open;
        case 'welcome':
          welcomeOpen = open;
        case 'pdf':
          sentPdf = true;
        case 'files':
          sentFiles = true;
        case 'tools':
          sentTools = true;
      }
      if (plan.at <= now + 120000) continue;
      if (rows.any((row) => _keyOf(row) == '${plan.kind}|${plan.at}')) continue;
      final used = <int>{
        for (final row in rows)
          if (_parse(row) != null) _parse(row)!.$1,
      };
      var id = 41001;
      while (used.contains(id)) {
        id++;
      }
      final when = tz.TZDateTime.from(DateTime.fromMillisecondsSinceEpoch(plan.at).toUtc(), tz.UTC);
      try {
        await _plugin.zonedSchedule(
          id,
          ReminderPlanner.titles[plan.kind] ?? 'Document Reader',
          ReminderPlanner.bodies[plan.kind] ?? '',
          when,
          const NotificationDetails(iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true, presentBanner: true, presentList: true)),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          payload: plan.kind,
        );
      } catch (error) {
        debugPrint('local reminder: $error');
        await _log(event: 'notification_delivery_failed', kind: plan.kind, id: id, status: 'failed', action: 'none', at: plan.at);
        continue;
      }
      rows.add('$id|${plan.kind}|${plan.at}');
    }
    await prefs.setStringList('local_plan', rows);
  }

  static Future<void> _record(SharedPreferences prefs, String kind, int at) async {
    final open = prefs.getInt('local_last_open_at') ?? at;
    await prefs.setInt('local_last_sent_at', at);
    await _bump(prefs, 'local_week_start', 'local_week_count', at);
    switch (kind) {
      case 'productivity':
        await _bump(prefs, 'local_prod_week_start', 'local_prod_count', at);
      case 'reading':
        await prefs.setInt('local_sent_reading_open', open);
      case 'document':
        await prefs.setInt('local_sent_document_open', open);
      case 'welcome':
        await prefs.setInt('local_sent_welcome_open', open);
      case 'pdf':
        await prefs.setBool('local_sent_pdf', true);
      case 'files':
        await prefs.setBool('local_sent_files', true);
      case 'tools':
        await prefs.setBool('local_sent_tools', true);
    }
  }

  static Future<void> _bump(SharedPreferences prefs, String weekKey, String countKey, int now) async {
    final week = DateTime.fromMillisecondsSinceEpoch(now);
    final day = DateTime(week.year, week.month, week.day);
    final back = (day.weekday + 6) % 7;
    final startMs = DateTime(day.year, day.month, day.day - back).millisecondsSinceEpoch;
    final count = prefs.getInt(weekKey) == startMs ? (prefs.getInt(countKey) ?? 0) : 0;
    await prefs.setInt(weekKey, startMs);
    await prefs.setInt(countKey, count + 1);
  }
}
