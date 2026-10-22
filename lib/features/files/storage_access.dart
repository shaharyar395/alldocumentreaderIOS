import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_shapes.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import '../../widgets/home_art.dart';

/// Whether the app may read the documents on the phone, like the Android app's
/// StorageAccess.has: Android 11+ "All files access", Android 10 and older the storage
/// permission. iOS has no such access (files come in through Files): always true.
Future<bool> hasStorageAccess() async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
  if (!Platform.isAndroid) return true;
  return PlatformBridge.storageAccess();
}

/// Opens the system page for "All files access" (Android 11+) or asks with the system
/// permission dialog (Android 10 and older). No dialog of our own. With a [context] the
/// "Welcome back" screen is not shown when the user comes back from the settings page.
Future<void> requestStorageAccess({BuildContext? context}) async {
  if (!Platform.isAndroid) return;
  if (context != null && context.mounted) {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
  }
  await PlatformBridge.requestStorageAccess();
}

/// Tools, the + sheet and file pickers (like the Android app's CreateFilesSheet.ensureAccess):
/// true when access is on; otherwise a "Allow file access…" toast, the settings page / system
/// dialog opens, and false is returned. Always true on iOS.
Future<bool> ensureAccess(BuildContext context) async {
  if (await hasStorageAccess()) return true;
  if (!context.mounted) return false;
  showToast(context, S.of(context).t('permissionNeededHint'));
  await requestStorageAccess(context: context);
  return false;
}

/// "Scan device storage": Android asks for storage access (the device scan then finds every
/// document); iOS lets the user pick a folder in Files whose documents are copied in.
Future<void> pickScanRoot(BuildContext context) async {
  final scope = AppScope.of(context);
  if (Platform.isAndroid) {
    if (await hasStorageAccess()) {
      await scope.library.rescan();
      return;
    }
    if (!context.mounted) return;
    await requestStorageAccess(context: context);
    if (await hasStorageAccess()) await scope.library.rescan();
    return;
  }
  scope.guard.arm(scope.settings);
  final path = await FilePicker.platform.getDirectoryPath();
  if (path == null || !context.mounted) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ios_scan_root', path);
  await PlatformBridge.rememberIosDirectory(path);
  await scope.library.rescan();
}

/// The "Allow access to files" dialog of the Android app (res/layout/dialog_permission.xml):
/// the All files icon, bold title, grey message, a full-width "Allow" pill and "Not now" below
/// it; as wide as the screen minus 56 dp. Returns true for Allow. [onContext] gets the dialog's
/// context so the caller can close it (e.g. when access was given meanwhile).
Future<bool> showStorageAccessDialog(BuildContext context, {void Function(BuildContext? dialogContext)? onContext}) async {
  final allow = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x52000000),
    builder: (dialogContext) {
      onContext?.call(dialogContext);
      final s = S.of(dialogContext);
      final c = NC.of(dialogContext);
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Container(
          width: double.infinity,
          decoration: NS.bgWhiteRound(dialogContext),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AllFilesGlyph(size: 64),
              const SizedBox(height: 14),
              Text(
                s.t('permissionTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                s.t('permissionMessage'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.32, color: c.textSecondary),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    foregroundColor: c.white,
                    elevation: 0,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: Text(s.t('allow'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 4),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => Navigator.pop(dialogContext, false),
                  child: SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: Center(
                      child: Text(s.t('notNow'), style: TextStyle(fontSize: 15, color: c.textSecondary)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  onContext?.call(null);
  return allow == true;
}

/// The dialog, then (on Allow) the settings page / system dialog. Returns whether access is on
/// right after (Android 11+ only knows when the user comes back from the settings page).
Future<bool> askStorageAccess(BuildContext context) async {
  if (await hasStorageAccess()) return true;
  if (!context.mounted) return false;
  final allow = await showStorageAccessDialog(context);
  if (!allow || !context.mounted) return false;
  await requestStorageAccess(context: context);
  return hasStorageAccess();
}
