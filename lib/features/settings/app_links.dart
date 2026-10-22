import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../services/platform_bridge.dart';
import '../files/directories_page.dart';
import '../premium/premium_page.dart';
import 'feedback_page.dart';
import 'terms_page.dart';

/// Support address of the Android app (util/Links.kt SUPPORT_EMAIL): Feedback is sent there.
const supportEmail = 'Mobappsinc@gmail.com';

/// Contact address of the Terms of use (the same as the Android app's).
const termsContactEmail = 'Mobappsinc@gmail.com';

const privacyPolicyUrl = 'https://sites.google.com/view/mob-apps-inc/privacy-policy';

/// Links inside the app's HTML texts: app://feedback, app://premium, app://terms and
/// app://filemanager open the matching screen; web links open in the browser.
Future<void> openAppLink(BuildContext context, String href) async {
  if (href == 'app://filemanager') {
    await openFileManager(context);
    return;
  }
  final Widget? page = switch (href) {
    'app://feedback' => const FeedbackPage(),
    'app://premium' => const PremiumPage(),
    'app://terms' => const TermsPage(),
    _ => null,
  };
  if (page != null) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return;
  }
  final uri = Uri.tryParse(href);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https') || uri.isScheme('mailto'))) return;
  final scope = AppScope.of(context);
  scope.guard.arm(scope.settings);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// "File manager" (Settings row, FAQ link): on Android the phone's own Files app, like the
/// Android app's Links.fileManager; if no app opens (and on iOS) the in-app storage browser.
Future<void> openFileManager(BuildContext context) async {
  if (Platform.isAndroid) {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    if (await PlatformBridge.openFileManager()) return;
    if (!context.mounted) return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DirectoriesPage()));
}
