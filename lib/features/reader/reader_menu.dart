import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';
import '../files/file_actions.dart';

/// The reader's ⋮ menu, like the Android viewer: file header (full path, tap for info), then
/// Rename, Bookmark, To home screen (Android), Save to Drive, and for PDF Pages / Print / Merge
/// PDF / Split PDF, then Delete — 4 per row.
Future<void> showReaderMenu(
  BuildContext context, {
  required DocEntry entry,
  required VoidCallback onDeleted,
  VoidCallback? onPages,
  VoidCallback? onPrint,
  VoidCallback? onMerge,
  VoidCallback? onSplit,
}) async {
  final s = S.of(context);
  final actions = <(NDrawable, String, Future<void> Function(), bool)>[
    (ND.icRename, s.t('rename'), () async => renameEntry(context, entry), false),
    (
      entry.bookmarked ? ND.icBookmark : ND.icBookmarkBorder,
      entry.bookmarked ? s.t('bookmarked') : s.t('bookmark'),
      () => toggleBookmarkWithPill(context, entry),
      false,
    ),
    if (!Platform.isIOS) (ND.icHomeAdd, s.t('toHomeScreen'), () => addToHomeScreen(context, entry), false),
    (ND.icStDrive, s.t('saveToDrive'), () => saveToDrive(context, entry), false),
    if (onPages != null) (ND.icPages, s.t('pagesMenu'), () async => onPages(), false),
    if (onPrint != null) (ND.icPrint, s.t('print'), () async => onPrint(), false),
    if (onMerge != null) (ND.icFeatMerge, s.t('mergePdf'), () async => onMerge(), false),
    if (onSplit != null) (ND.icSplitLine, s.t('splitPdf'), () async => onSplit(), false),
    (
      ND.icDelete,
      s.t('delete'),
      () async {
        await confirmDelete(context, entry);
        if (!context.mounted) return;
        final library = AppScope.of(context).library;
        final stillThere = library.entries.any((e) => e.id == entry.id && !e.inBin);
        if (!stillThere) onDeleted();
      },
      false,
    ),
  ];
  final chosen = await showAppSheet<int>(
    context,
    builder: (sheet) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FileMenuHeader(entry: entry, onTap: () => Navigator.pop(sheet, -1)),
              Container(height: 1, color: NC.of(sheet).divider),
              const SizedBox(height: 10),
              for (var row = 0; row < actions.length; row += 4)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = row; i < row + 4; i++)
                        Expanded(
                          child: i >= actions.length
                              ? const SizedBox.shrink()
                              : FileActionTile(
                                  drawable: actions[i].$1,
                                  label: actions[i].$2,
                                  danger: actions[i].$4,
                                  onTap: () => Navigator.pop(sheet, i),
                                ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (chosen == null || !context.mounted) return;
  if (chosen == -1) {
    await showDetails(context, entry);
    return;
  }
  if (chosen >= 0 && chosen < actions.length) await actions[chosen].$3();
}
