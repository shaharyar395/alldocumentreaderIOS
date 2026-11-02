import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/file_library.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_shapes.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import '../../widgets/home_art.dart';

/// Whether the app may read the documents on the phone, like the Android app's
/// StorageAccess.has: Android 11+ "All files access", Android 10 and older the storage
/// permission. iOS lets no app read the whole phone: there, access means the user has picked
/// at least one folder in Files (On My iPhone, Downloads, iCloud Drive…).
Future<bool> hasStorageAccess() async {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return true;
  if (Platform.isIOS) return (await PlatformBridge.iosFolders()).isNotEmpty;
  if (!Platform.isAndroid) return true;
  return PlatformBridge.storageAccess();
}

/// Whether tools, lists and pickers must wait for file access first: only on Android without
/// "All files access" / the storage permission (like the Android app's needsAccess). iOS is fully
/// usable without a picked folder: the app's own files (Documents) are always there, and picked
/// folders only add more files to the lists.
Future<bool> needsAccessGate() async => Platform.isAndroid && !await hasStorageAccess();

/// Opens the system page for "All files access" (Android 11+) or asks with the system
/// permission dialog (Android 10 and older). No dialog of our own. With a [context] the
/// "Welcome back" screen is not shown when the user comes back from the settings page.
/// iOS: the Files folder picker; a picked folder is scanned straight away.
Future<void> requestStorageAccess({BuildContext? context}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  FileLibrary? library;
  if (context != null && context.mounted) {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    library = scope.library;
  }
  if (Platform.isIOS) {
    final picked = await PlatformBridge.pickIosFolder();
    if (picked != null) await library?.rescan();
    return;
  }
  await PlatformBridge.requestStorageAccess();
}

/// Tools, the + sheet and file pickers (like the Android app's CreateFilesSheet.ensureAccess):
/// true when access is on; otherwise a "Allow file access…" toast, the settings page / system
/// dialog opens, and false is returned. Always true on iOS ([needsAccessGate]).
Future<bool> ensureAccess(BuildContext context) async {
  if (!await needsAccessGate()) return true;
  if (!context.mounted) return false;
  showToast(context, S.of(context).t('permissionNeededHint'));
  await requestStorageAccess(context: context);
  return false;
}

/// "Scan device storage" / "Add folder": Android asks for storage access (the device scan then
/// finds every document); iOS opens the Files folder picker (another folder can be added any time).
Future<void> pickScanRoot(BuildContext context) async {
  final scope = AppScope.of(context);
  if (Platform.isAndroid && await hasStorageAccess()) {
    await scope.library.rescan();
    return;
  }
  if (!context.mounted) return;
  await requestStorageAccess(context: context);
  if (Platform.isAndroid && await hasStorageAccess()) await scope.library.rescan();
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
                s.t(Platform.isIOS ? 'permissionMessageIos' : 'permissionMessage'),
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
