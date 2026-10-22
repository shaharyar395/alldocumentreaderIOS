import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../data/doc_entry.dart';
import '../../data/file_library.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/bookmark_pill.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart';
import '../reader/reader_page.dart';
import 'device_files.dart';
import 'files_ui.dart';

/// Opens a document like the Android app's FileActions.open: PDF, TXT, pictures, xlsx / ods /
/// csv, docx and pptx open in the app; the other Word / Excel / PowerPoint types (doc, rtf, odt,
/// xls, ppt, odp …) go to another app on the phone; anything else, or a type no app can open,
/// gets the "File type not supported" sheet.
Future<void> openEntry(BuildContext context, DocEntry entry) async {
  final scope = AppScope.of(context);
  final library = scope.library;
  final path = entry.fullPath;
  if (!File(path).existsSync()) {
    showToast(context, S.of(context).t('fileGone'));
    return;
  }
  if (opensInApp(entry.name)) {
    await library.markOpened(entry);
    if (!context.mounted) return;
    final fresh = library.entries.cast<DocEntry?>().firstWhere((e) => e?.id == entry.id, orElse: () => entry)!;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReaderPage(entry: fresh)));
    return;
  }
  if (entry.kind == DocKind.other) {
    await showUnsupported(context);
    return;
  }
  await library.markOpened(entry);
  // the system app chooser is not "leaving the app": no Welcome back after it
  scope.guard.arm(scope.settings);
  final opened = await PlatformBridge.openExternal(path);
  if (!opened && context.mounted) await showUnsupported(context);
}

/// Opens a file found on the device (storage browser / All documents).
Future<void> openDevicePath(BuildContext context, DeviceItem item) async {
  final library = AppScope.of(context).library;
  final entry = await libraryEntryFor(library, item.path);
  if (!context.mounted) return;
  await openEntry(context, entry ?? deviceEntry(item));
}

/// The ⋮ menu for a file found on the device (long-press in Directories).
Future<void> showDeviceFileMenu(BuildContext context, DeviceItem item) async {
  final library = AppScope.of(context).library;
  final entry = await libraryEntryFor(library, item.path);
  if (!context.mounted) return;
  await showFileMenu(context, entry ?? deviceEntry(item));
}

/// "File type not supported" with OK and FAQ (sheet_unsupported.xml; FAQ: a short dialog listing
/// what opens where).
Future<void> showUnsupported(BuildContext context) async {
  final s = S.of(context);
  final faq = await showAppSheet<bool>(
    context,
    builder: (sheetContext) {
      final c = NC.of(sheetContext);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const NativeIcon(ND.icUnsupported, width: 140, height: 120),
              const SizedBox(height: 10),
              Text(s.t('unsupportedTitle'), textAlign: TextAlign.center, style: sheetTitleStyle(sheetContext)),
              const SizedBox(height: 8),
              Text(
                s.t('unsupportedMessage'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.45, color: c.textPrimary),
              ),
              const SizedBox(height: 18),
              NativePillButton(label: s.t('ok'), onPressed: () => Navigator.pop(sheetContext, false)),
              const SizedBox(height: 4),
              SizedBox(
                height: 40,
                child: InkWell(
                  onTap: () => Navigator.pop(sheetContext, true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NativeIcon(ND.icHelp, size: 16, tint: c.primary),
                        const SizedBox(width: 4),
                        Text(s.t('faq'), style: TextStyle(fontSize: 14, color: c.primary)),
                      ],
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
  if (faq != true || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(s.t('faq')),
      content: Text(s.t('unsupportedFaqMessage')),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(s.t('ok')))],
    ),
  );
}

/// Bookmark / remove the bookmark, with the dark "Bookmarked" pill of the Android app.
Future<void> toggleBookmarkWithPill(BuildContext context, DocEntry entry) async {
  final library = AppScope.of(context).library;
  final current = library.entries.cast<DocEntry?>().firstWhere((e) => e?.id == entry.id, orElse: () => entry)!;
  final added = !current.bookmarked;
  await library.toggleBookmark(current);
  if (!context.mounted) return;
  showBookmarkPill(context, added: added);
}

Future<void> shareEntry(BuildContext context, DocEntry entry) async {
  await shareEntries(context, [entry]);
}

/// Shares one or several files in one share sheet.
Future<void> shareEntries(BuildContext context, List<DocEntry> entries) async {
  if (entries.isEmpty) return;
  final scope = AppScope.of(context);
  final files = [
    for (final entry in entries)
      if (File(entry.fullPath).existsSync()) XFile(entry.fullPath),
  ];
  if (files.isEmpty) {
    showToast(context, S.of(context).t('fileGone'));
    return;
  }
  scope.guard.arm(scope.settings);
  await Share.shareXFiles(files);
}

/// Grey circle behind the menu icons (Android bg_circle_action: @color/surface_variant).
Color actionCircleColor(BuildContext context) => NC.of(context).surfaceVariant;

/// One icon + label tile of the ⋮ sheets (Android item_file_action): a 48dp surface_variant
/// circle with a 22dp primary icon, the 13sp label 8dp below, borderless ripple. Give the native
/// [drawable] (ic_share, ic_rename …); [icon] is the Material fallback when there is none.
class FileActionTile extends StatelessWidget {
  const FileActionTile({super.key, this.icon, this.drawable, required this.label, required this.onTap, this.danger = false});

  final IconData? icon;
  final NDrawable? drawable;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final tint = danger ? c.danger : c.primary;
    final art = drawable;
    return InkResponse(
      onTap: onTap,
      radius: 44,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10, left: 2, right: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: NS.bgCircleAction(context),
              alignment: Alignment.center,
              child: art != null ? NativeIcon(art, size: 22, tint: tint) : Icon(icon ?? Icons.circle_outlined, size: 22, color: tint),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: c.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header of the ⋮ sheets (sheet_file_menu.xml): 36dp type icon, 16sp bold name, the full path
/// (12sp, 2 lines) and › — tapping it opens the info sheet.
class FileMenuHeader extends StatelessWidget {
  const FileMenuHeader({super.key, required this.entry, required this.onTap});

  final DocEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 16, 14),
        child: Row(
          children: [
            FileKindIcon(kind: entry.kind, size: 36),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(entry.fullPath, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                ],
              ),
            ),
            NativeIcon(ND.icChevronRight, size: 22, tint: c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// The ⋮ sheet of a file row, like the Android sheet_file_menu: header (→ info), then Share,
/// Rename, To home screen (Android), Save to Drive and Delete. Completes once the chosen action
/// is done, so lists can reload afterwards.
Future<void> showFileMenu(BuildContext context, DocEntry entry) async {
  final s = S.of(context);
  final actions = <(NDrawable, String, Future<void> Function())>[
    (ND.icShare, s.t('share'), () => shareEntry(context, entry)),
    (ND.icRename, s.t('rename'), () => renameEntry(context, entry)),
    if (!Platform.isIOS) (ND.icHomeAdd, s.t('toHomeScreen'), () => addToHomeScreen(context, entry)),
    (ND.icStDrive, s.t('saveToDrive'), () => saveToDrive(context, entry)),
    (ND.icDelete, s.t('delete'), () => confirmDelete(context, entry)),
  ];
  final chosen = await showAppSheet<int>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FileMenuHeader(entry: entry, onTap: () => Navigator.pop(sheet, -1)),
            Container(height: 1, color: NC.of(sheet).divider),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < actions.length; i++)
                    Expanded(
                      child: FileActionTile(
                        drawable: actions[i].$1,
                        label: actions[i].$2,
                        onTap: () => Navigator.pop(sheet, i),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  if (chosen == -1) {
    await showDetails(context, entry);
    return;
  }
  if (chosen >= 0 && chosen < actions.length) await actions[chosen].$3();
}

/// Info sheet (Android sheet_file_info): icon, name, size, "Storage path" with the full path,
/// "Last modified" as HH:mm  MM/dd/yyyy, and a close button.
Future<void> showDetails(BuildContext context, DocEntry entry) {
  final s = S.of(context);
  String two(int v) => v.toString().padLeft(2, '0');
  final m = entry.modified;
  final when = '${two(m.hour)}:${two(m.minute)}  ${two(m.month)}/${two(m.day)}/${m.year}';
  return showAppSheet<void>(
    context,
    builder: (sheet) {
      final c = NC.of(sheet);
      final label = TextStyle(fontSize: 13, color: c.textSecondary);
      final value = TextStyle(fontSize: 14, color: c.textPrimary);
      return SafeArea(
        top: false,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: FileKindIcon(kind: entry.kind, size: 52)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: Text(entry.name, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    width: double.infinity,
                    child: Text(formatBytes(entry.bytes), textAlign: TextAlign.center, style: label),
                  ),
                  const SizedBox(height: 24),
                  Text(s.t('fileInfoStoragePath'), style: label),
                  const SizedBox(height: 4),
                  SelectableText(entry.fullPath, style: value),
                  const SizedBox(height: 18),
                  Text(s.t('fileInfoLastModified'), style: label),
                  const SizedBox(height: 4),
                  Text(when, style: value),
                ],
              ),
            ),
            SheetCloseButton(tooltip: s.t('cancel'), onTap: () => Navigator.pop(sheet)),
          ],
        ),
      );
    },
  );
}

/// Rename sheet (Android sheet_rename): the name without its extension, all selected, a clear
/// button, an error line ("Name cannot be empty" …), Cancel / OK; "Renamed" when it worked.
/// Returns the renamed entry, or null when nothing changed.
Future<DocEntry?> renameEntry(BuildContext context, DocEntry entry) async {
  final s = S.of(context);
  final library = AppScope.of(context).library;
  final dot = entry.name.lastIndexOf('.');
  final base = dot > 0 ? entry.name.substring(0, dot) : entry.name;
  final controller = TextEditingController(text: base);
  controller.selection = TextSelection(baseOffset: 0, extentOffset: base.length);
  String? error;
  var busy = false;
  final renamed = await showAppSheet<bool>(
    context,
    builder: (sheet) => StatefulBuilder(
      builder: (sheetContext, setSheet) {
        final c = NC.of(sheetContext);
        Future<void> submit() async {
          if (busy) return;
          final text = controller.text.trim();
          if (text == base) {
            Navigator.pop(sheet, false);
            return;
          }
          String? local;
          if (text.isEmpty) {
            local = 'renameEmpty';
          } else if (RegExp(r'[\\/:*?"<>|]').hasMatch(text)) {
            local = 'renameInvalid';
          }
          if (local != null) {
            final message = s.t(local);
            setSheet(() => error = message);
            return;
          }
          setSheet(() => busy = true);
          RenameResult result;
          try {
            result = await library.renameChecked(entry, text);
          } catch (_) {
            result = RenameResult.failed;
          }
          if (!sheetContext.mounted) return;
          setSheet(() => busy = false);
          final key = switch (result) {
            RenameResult.ok => null,
            RenameResult.empty => 'renameEmpty',
            RenameResult.invalid => 'renameInvalid',
            RenameResult.exists => 'renameExists',
            RenameResult.failed => 'renameFailed',
          };
          if (key == null) {
            Navigator.pop(sheet, true);
          } else {
            setSheet(() => error = s.t(key));
          }
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Text(s.t('rename'), style: sheetTitleStyle(sheetContext))),
                const SizedBox(height: 16),
                // bg_rename_field: surface, 1.5dp primary outline, 10dp corners
                Container(
                  height: 50,
                  padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
                  decoration: NS.bgRenameField(sheetContext),
                  child: Row(
                    children: [
                      Expanded(
                        child: NativeTextField(
                          controller: controller,
                          hint: '',
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setSheet(() => error = null),
                          onSubmitted: (_) => submit(),
                        ),
                      ),
                      // INVISIBLE (keeps its place) when the field is empty
                      Visibility(
                        visible: controller.text.isNotEmpty,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: RowIconButton(
                          drawable: ND.icClose,
                          size: 36,
                          padding: 10,
                          tint: c.textSecondary,
                          onTap: () => setSheet(() {
                            controller.clear();
                            error = null;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(error!, style: TextStyle(fontSize: 12, color: c.danger)),
                  ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: NativePillButton(label: s.t('cancel'), gray: true, onPressed: () => Navigator.pop(sheet, false)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: NativePillButton(label: s.t('ok'), onPressed: busy ? null : submit),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  final newName = '${controller.text.trim()}${dot > 0 ? entry.name.substring(dot) : ''}';
  controller.dispose();
  if (renamed != true || !context.mounted) return null;
  showToast(context, s.t('renamed'));
  for (final e in library.entries) {
    if (e.id == entry.id) return e;
  }
  for (final e in library.entries) {
    if (!e.inBin && e.name == newName) return e;
  }
  return null;
}

/// "To home screen": on Xiaomi / Redmi / POCO the "Home screen shortcuts" permission sheet comes
/// first (once); then the launcher is asked to pin a shortcut with the file type's icon.
Future<void> addToHomeScreen(BuildContext context, DocEntry entry) async {
  final s = S.of(context);
  if (!Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  final xiaomi = await PlatformBridge.isXiaomi();
  if (!context.mounted) return;
  if (xiaomi && !(prefs.getBool('shortcut_permission_asked') ?? false)) {
    final allow = await _shortcutPermissionSheet(context);
    if (allow != true) return;
    await prefs.setBool('shortcut_permission_asked', true);
    if (!context.mounted) return;
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    await PlatformBridge.openAppDetails();
    return;
  }
  final ok = await PlatformBridge.pinShortcut(entry.fullPath, entry.name, kind: entry.kind.name);
  if (!context.mounted) return;
  showToast(context, ok ? s.t('shortcutAdded') : s.t('shortcutNotSupported'));
}

Future<bool?> _shortcutPermissionSheet(BuildContext context) {
  final s = S.of(context);
  return showAppSheet<bool>(
    context,
    builder: (sheet) {
      final c = NC.of(sheet);
      return SafeArea(
        top: false,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const NativeIcon(ND.icShortcutPermission, width: 140, height: 110),
                  const SizedBox(height: 12),
                  Text(s.t('shortcutPermissionTitle'), textAlign: TextAlign.center, style: sheetTitleStyle(sheet)),
                  const SizedBox(height: 8),
                  Text.rich(
                    _quotedInPrimary(s.t('shortcutPermissionMessage'), c.primary),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: c.textPrimary),
                  ),
                  const SizedBox(height: 20),
                  NativePillButton(label: s.t('allow'), onPressed: () => Navigator.pop(sheet, true)),
                ],
              ),
            ),
            SheetCloseButton(tooltip: s.t('cancel'), onTap: () => Navigator.pop(sheet, false)),
          ],
        ),
      );
    },
  );
}

/// The quoted part ("Home screen shortcuts") in primary, like the native `<font color>` message.
TextSpan _quotedInPrimary(String text, Color primary) {
  final match = RegExp('["\u201C\u201E\u00AB\u300C\u300E\u2018](.+?)["\u201D\u201C\u00BB\u300D\u300F\u2019]').firstMatch(text);
  if (match == null) return TextSpan(text: text);
  return TextSpan(children: [
    TextSpan(text: text.substring(0, match.start)),
    TextSpan(text: match.group(0), style: TextStyle(color: primary)),
    TextSpan(text: text.substring(match.end)),
  ]);
}

/// "Save to Drive": the file goes straight to the Google Drive app's upload screen; without the
/// Drive app, "Couldn't save to Google Drive" with Install (Google Play). iOS: the share sheet.
Future<void> saveToDrive(BuildContext context, DocEntry entry) async {
  final s = S.of(context);
  final path = entry.fullPath;
  if (!File(path).existsSync()) {
    showToast(context, s.t('fileGone'));
    return;
  }
  final scope = AppScope.of(context);
  scope.guard.arm(scope.settings);
  final result = await PlatformBridge.saveToDrive(path);
  if (result == 'ok' || !context.mounted) return;
  final install = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(s.t('driveSaveFailedTitle')),
      content: Text(s.t('driveAppMissing')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(s.t('cancel'))),
        TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(s.t('driveInstall'))),
      ],
    ),
  );
  if (install != true || !context.mounted) return;
  scope.guard.arm(scope.settings);
  const id = 'com.google.android.apps.docs';
  try {
    final market = await launchUrl(Uri.parse('market://details?id=$id'), mode: LaunchMode.externalApplication);
    if (market) return;
  } catch (_) {
    // no Play Store app: the web page
  }
  try {
    await launchUrl(Uri.parse('https://play.google.com/store/apps/details?id=$id'), mode: LaunchMode.externalApplication);
  } catch (error) {
    debugPrint('install drive: $error');
  }
}

Future<void> confirmDelete(BuildContext context, DocEntry entry) async {
  await confirmDeleteMany(context, [entry]);
}

/// "Move to recycle bin or delete?" for one or several files. Returns true when files were
/// moved / deleted.
Future<bool> confirmDeleteMany(BuildContext context, List<DocEntry> entries) async {
  if (entries.isEmpty) return false;
  final s = S.of(context);
  final choice = await showAppSheet<String>(
    context,
    builder: (sheetContext) {
      final c = NC.of(sheetContext);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.t('recycleTitle'), textAlign: TextAlign.center, style: sheetTitleStyle(sheetContext)),
              const SizedBox(height: 10),
              Text(s.t('recycleMessage'), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.textPrimary)),
              const SizedBox(height: 20),
              NativePillButton(label: s.t('moveToBin'), onPressed: () => Navigator.pop(sheetContext, 'bin')),
              const SizedBox(height: 12),
              NativePillButton(
                label: s.t('deleteDirectly'),
                gray: true,
                textColor: c.danger,
                onPressed: () => Navigator.pop(sheetContext, 'forever'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || choice == null) return false;
  final library = AppScope.of(context).library;
  final toBin = choice == 'bin';
  final done = toBin ? await library.moveManyToBin(entries) : await library.deleteManyForever(entries);
  if (!context.mounted) return done > 0;
  if (done > 0) showToast(context, s.t(toBin ? 'movedToBinCount' : 'deletedCount', {'count': '$done'}));
  if (done < entries.length) showToast(context, s.t('deleteSomeFailed'));
  return done > 0;
}

/// [FileLibrary] entry with this id as it is now (after a rename / bookmark), or [entry].
DocEntry currentEntry(FileLibrary library, DocEntry entry) {
  for (final e in library.entries) {
    if (e.id == entry.id) return e;
  }
  return entry;
}
