import 'ios_analytics.dart';

/// Action events with the same names and parameters as the Android app (analytics/AppAnalytics.kt).
/// Everything goes through [IosAnalytics] (Firebase Analytics on iOS: name / parameter rules,
/// blocked names, last_action), so there is one analytics pipeline.
void logEvent(String name, [Map<String, Object> params = const {}]) => IosAnalytics.log(name, params);
