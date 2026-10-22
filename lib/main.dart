import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/settings/app_settings.dart';
import 'data/file_library.dart';
import 'l10n/s.dart';
import 'services/ad_service.dart';
import 'services/billing_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await S.preload();
  final settings = await AppSettings.load();
  final library = FileLibrary();
  // every file the app saves counts for "Do you think … is helpful?"
  library.onSaved = settings.noteSaved;
  final ads = AdService(settings);
  final billing = BillingService(settings);
  runApp(AllDocApp(settings: settings, library: library, ads: ads, billing: billing));
}
