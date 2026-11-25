import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/settings/app_settings.dart';
import 'data/file_library.dart';
import 'data/reading_progress.dart';
import 'l10n/s.dart';
import 'services/ad_remote_config.dart';
import 'services/ad_service.dart';
import 'services/apple_billing.dart';
import 'services/billing_service.dart';
import 'services/in_app_messages.dart';
import 'services/ios_analytics.dart';
import 'services/ios_growth.dart';
import 'services/push_notifications.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS && !Platform.environment.containsKey('FLUTTER_TEST')) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  await IosGrowth.start();
  // ad switches from Firebase Remote Config (Android 1.0.75); fetches in the background
  await AdRemoteConfig.start();
  await AppleBilling.initBackend();
  await InAppMessages.start();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await S.preload();
  final settings = await AppSettings.load();
  await ReadingProgress.init();
  final library = FileLibrary();
  // every file the app saves counts for "Do you think … is helpful?"
  library.onSaved = settings.noteSaved;
  final ads = AdService(settings);
  final billing = BillingService(settings);
  await IosAnalytics.bindUser(settings);
  settings.addListener(() => IosAnalytics.bindUser(settings));
  runApp(AllDocApp(settings: settings, library: library, ads: ads, billing: billing));
}
