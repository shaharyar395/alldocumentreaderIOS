import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import '../create/pdf_picker_page.dart';
import '../create/tool_widgets.dart';
import '../reader/reader_page.dart';
import 'manage_pages_page.dart';
import 'markup_page.dart';

/// Tools of the PDF editor. [text] = Add text, [editText] = Edit text (retype a line of the PDF),
/// [image] = Add image, [sign] = Sign, the others are Annotate tools.
enum MarkTool { pen, highlight, underline, strike, eraser, text, image, sign, editText }

/// The PDF editor with [tool]. With an [entry] (the reader's tools, a result page) it opens on
/// top of the current screen; from Tools / the widget it first asks "Select a file" (PDFs and
/// pictures — a picture becomes a PDF first) and then opens the reader with the editor on top,
/// so back from the editor lands in the reader, like the Android app.
Future<void> openMarkup(BuildContext context, {DocEntry? entry, MarkTool tool = MarkTool.pen}) async {
  if (entry != null) {
    if (entry.kind != DocKind.pdf) {
      showToast(context, S.of(context).t('noTextLayer'));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MarkupPage(entry: entry, tool: tool)));
    return;
  }
  final target = await pickPdfOrImage(context);
  if (!context.mounted || target == null) return;
  final navigator = Navigator.of(context);
  await AppScope.of(context).library.markOpened(target);
  // the reader under the editor (not awaited: it stays open below)
  navigator.push(MaterialPageRoute<void>(builder: (_) => ReaderPage(entry: target)));
  await navigator.push(MaterialPageRoute<void>(builder: (_) => MarkupPage(entry: target, tool: tool)));
}

/// Manage pages: [entry], or "Select a file" with PDFs and pictures.
Future<void> openManagePages(BuildContext context, {DocEntry? entry}) async {
  final target = entry ?? await pickPdfOrImage(context);
  if (!context.mounted || target == null) return;
  if (target.kind != DocKind.pdf) {
    showToast(context, S.of(context).t('noTextLayer'));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ManagePagesPage(entry: target)));
}

/// "Select a file" for the edit / pages / print tools: the PDFs and pictures on the phone
/// (Browse for others). A picture is turned into a PDF first ("Converting… (x%)"), like the
/// Android PickFileActivity.
Future<DocEntry?> pickPdfOrImage(BuildContext context) async {
  final scope = AppScope.of(context);
  final pick = await pickOnePdf(
    context,
    kinds: const {DocKind.pdf, DocKind.image},
    extensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic', 'heif'],
  );
  if (pick == null || !context.mounted) return null;
  final kind = kindForName(pick.name);
  if (kind == DocKind.image) return imageToPdfEntry(context, pick.path, pick.name);
  if (kind != DocKind.pdf) {
    showToast(context, S.of(context).t('unsupportedTitle'));
    return null;
  }
  final entry = pick.entry;
  if (entry != null) return entry;
  // a file browsed from another app is copied in first, like an import
  return scope.library.importPath(pick.path, name: pick.name);
}

/// Converts the picture at [path] to a PDF saved with the converted files ("photo.pdf").
Future<DocEntry?> imageToPdfEntry(BuildContext context, String path, String name) async {
  final s = S.of(context);
  final library = AppScope.of(context).library;
  final pill = ProgressPill(context)..show(s.t('convertingProgress', {'percent': '0'}));
  DocEntry? saved;
  try {
    final bytes = await File(path).readAsBytes();
    final pdf = await imagesToPdf(
      [bytes],
      onProgress: (value) => pill.show(s.t('convertingProgress', {'percent': '${(value * 100).clamp(0, 99).round()}'})),
    );
    final stem = p.basenameWithoutExtension(name);
    saved = await library.importBytes(pdf, name: '${stem.isEmpty ? 'Image' : stem}.pdf', folder: 'convert');
  } catch (_) {
    saved = null;
  }
  pill.dismiss();
  if (saved == null && context.mounted) showToast(context, s.t('convertFailed'));
  return saved;
}
