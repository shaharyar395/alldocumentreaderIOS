import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:printing/printing.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/ocr_service.dart';
import '../../services/office_pdf.dart';
import '../../services/office_text.dart';
import '../../services/pdf_text.dart';
import '../../widgets/chrome.dart';
import '../create/blank_pages_page.dart';
import '../create/image_pdf_page.dart';
import '../create/merge_page.dart';
import '../create/pdf_picker_page.dart';
import '../create/scan_flow.dart';
import '../create/split_page.dart';
import '../create/success_page.dart';
import '../create/templates_page.dart';
import '../create/tool_widgets.dart';
import '../editor/editor_flow.dart';
import '../files/file_actions.dart';
import '../files/storage_access.dart';

/// The "+" sheet, like the Android sheet_create_files: "Create files" with Import files, Use
/// templates and Create PDF cards (item_create_card), then "Convert format" with Image to PDF,
/// Scan to PDF, Word to PDF, PDF to Word and PPT to PDF tiles (item_convert_tile). Every item
/// needs file access first.
Future<void> showCreateSheet(BuildContext context) {
  final s = S.of(context);
  final cards = <(NDrawable, String, Future<void> Function())>[
    (ND.icCreateImport, s.t('importFiles'), () => importFiles(context)),
    (ND.icCreateTemplates, s.t('useTemplates'), () => openTemplates(context)),
    (ND.icCreatePdfBadge, s.t('createPdf'), () => createBlankPdf(context)),
  ];
  final tiles = <(NDrawable, String, Future<void> Function())>[
    (ND.icCvImage2pdf, s.t('imageToPdf'), () => imageToPdfFromList(context)),
    (ND.icCvScan, s.t('scanToPdf'), () => pickImages(context, camera: true)),
    (ND.icCvWord2pdf, s.t('wordToPdf'), () => convertOffice(context, slides: false)),
    (ND.icCvPdf2word, s.t('pdfToWord'), () => convertPdfToWord(context)),
    (ND.icCvPpt2pdf, s.t('pptToPdf'), () => convertOffice(context, slides: true)),
  ];
  return showAppSheet<void>(
    context,
    builder: (sheet) {
      final c = NC.of(sheet);
      void run(Future<void> Function() action) {
        Navigator.pop(sheet);
        ensureAccess(context).then((ok) {
          if (ok && context.mounted) action();
        });
      }

      // item_create_card: 52 dp, bg_create_card (surface_variant, 10 dp, ripple), 30 dp icon,
      // 14 sp bold label, 5 dp margin
      Widget card((NDrawable, String, Future<void> Function()) item) {
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Material(
              color: c.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => run(item.$3),
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
                    child: Row(
                      children: [
                        NativeIcon(item.$1, size: 30),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            item.$2,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      // item_convert_tile: borderless ripple, a 52 dp bg_create_card square with the 30 dp icon,
      // the 13 sp label 6 dp below; 4 dp top / 8 dp bottom padding
      Widget tile((NDrawable, String, Future<void> Function())? item) {
        if (item == null) return const Expanded(child: SizedBox.shrink());
        return Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: () => run(item.$3),
              containedInkWell: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: NS.bgCreateCard(sheet),
                      child: NativeIcon(item.$1, size: 30),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.$2,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: c.textPrimary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      // SheetTitle at 16 sp
      Widget title(String text, {double top = 0, double bottom = 4}) {
        return Padding(
          padding: EdgeInsetsDirectional.only(start: 5, top: top, bottom: bottom),
          child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
        );
      }

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(11, 18, 11, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title(s.t('createFiles')),
              Row(children: [card(cards[0]), card(cards[1])]),
              Row(children: [card(cards[2]), const Expanded(child: SizedBox.shrink())]),
              title(s.t('convertFormat'), top: 14, bottom: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [tile(tiles[0]), tile(tiles[1]), tile(tiles[2]), tile(tiles[3])]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [tile(tiles[4]), tile(null), tile(null), tile(null)]),
            ],
          ),
        ),
      );
    },
  );
}

/// "Import files": the system file browser; the chosen file opens straight away. Types the app
/// does not handle get "File type not supported".
Future<void> importFiles(BuildContext context) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  scope.guard.arm(scope.settings);
  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles();
  } catch (_) {
    result = null;
  }
  if (result == null || result.files.isEmpty || !context.mounted) return;
  final file = result.files.first;
  if (kindForName(file.name) == DocKind.other) {
    showToast(context, s.t('unsupportedTitle'));
    return;
  }
  DocEntry? entry;
  try {
    final path = file.path;
    final bytes = file.bytes;
    if (path != null) {
      entry = await scope.library.importPath(path, name: file.name);
    } else if (bytes != null) {
      entry = await scope.library.importBytes(bytes, name: file.name);
    }
  } catch (error) {
    debugPrint('import: $error');
  }
  if (!context.mounted) return;
  if (entry == null) {
    showToast(context, s.t('importFailedToast'));
    return;
  }
  await openEntry(context, entry);
}

/// Tools → Image to PDF ([camera] false: "Take a photo / Choose from gallery / Cancel") or
/// Scan to PDF ([camera] true: the document scanner straight away) → page editor.
Future<void> pickImages(BuildContext context, {required bool camera}) {
  return camera ? startScanToPdf(context) : startImageToPdf(context);
}

/// "+" sheet → Image to PDF: "Select a file" with the pictures on the phone → Image to PDF list.
Future<void> imageToPdfFromList(BuildContext context) async {
  final pick = await pickOnePdf(
    context,
    kinds: const {DocKind.image},
    extensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic', 'heif'],
  );
  if (pick == null || !context.mounted) return;
  final job = ScanJob();
  job.pages.add(job.newPage(pick.path));
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ImagePdfPage(job: job)));
}

/// Create PDF: file name, template, page size, colour, orientation and count.
Future<void> createBlankPdf(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BlankPagesPage(createMode: true)));
}

/// Formats the converters can read (Android ConvertKind.canConvert): old binary .doc / .ppt
/// (and rtf, odt …) are not supported.
bool canConvertOffice(String name, {required bool slides}) {
  final dot = name.lastIndexOf('.');
  final ext = dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  return slides ? const {'pptx', 'ppsx', 'potx'}.contains(ext) : const {'docx', 'docm', 'dotx', 'txt'}.contains(ext);
}

/// Word to PDF (Word / TXT) or PPT to PDF: "Select a file" → "Converting… (x%)" → Converted
/// successfully. The layout is kept (paragraph styles, tables, pictures, slides).
Future<void> convertOffice(BuildContext context, {required bool slides, DocEntry? entry}) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  String? path;
  String name;
  if (entry != null) {
    if (!canConvertOffice(entry.name, slides: slides)) {
      showToast(context, s.t('convertOldFormat'));
      return;
    }
    path = entry.fullPath;
    name = entry.name;
  } else {
    final pick = await pickOnePdf(
      context,
      kinds: slides ? const {DocKind.ppt} : const {DocKind.word, DocKind.txt},
      extensions: slides
          ? const ['ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'pot', 'potx', 'odp']
          : const ['doc', 'docx', 'docm', 'dot', 'dotx', 'rtf', 'odt', 'txt'],
      accept: (name) => canConvertOffice(name, slides: slides),
      rejectMessage: s.t('convertOldFormat'),
    );
    if (pick == null) return;
    path = pick.path;
    name = pick.name;
  }
  if (!context.mounted) return;
  final pill = ProgressPill(context)..show(s.t('convertingProgress', {'percent': '0'}));
  try {
    final bytes = await officeFileToPdf(
      path,
      onProgress: (value) => pill.show(s.t('convertingProgress', {'percent': '${(value * 100).clamp(0, 99).round()}'})),
    );
    final stem = p.basenameWithoutExtension(name);
    final saved = await scope.library.importBytes(bytes, name: '${stem.isEmpty ? 'Document' : stem}.pdf', folder: 'convert');
    pill.dismiss();
    if (!context.mounted) return;
    if (saved == null) throw StateError('save');
    await scope.ads.showInterstitial();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SuccessPage(
          entry: saved,
          kind: ResultKind.converted,
          feature: s.t(slides ? 'pptToPdf' : 'wordToPdf'),
          featureKey: slides ? 'ppt_to_pdf' : 'word_to_pdf',
        ),
      ),
    );
  } catch (_) {
    pill.dismiss();
    if (context.mounted) showToast(context, s.t('convertFailed'), warning: true);
  }
}

Future<void> convertPdfToWord(BuildContext context, {DocEntry? entry}) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  String? path = entry?.fullPath;
  var name = entry?.name ?? 'Document.pdf';
  if (path == null) {
    final pick = await pickOnePdf(context);
    if (pick == null) return;
    path = pick.path;
    name = pick.name;
  }
  if (!context.mounted) return;
  final source = path;
  final pill = ProgressPill(context)..show(s.t('convertingProgress', {'percent': '0'}));
  try {
    final bytes = await File(source).readAsBytes();
    pill.show(s.t('convertingProgress', {'percent': '20'}));
    var text = extractPdfText(bytes);
    if (text.trim().isEmpty) {
      text = await ocrPdf(
        source,
        languageTag: scope.settings.languageTag,
        onPage: (done, total) => pill.show(s.t('convertingProgress', {'percent': '${(20 + done / total * 70).round()}'})),
      );
    }
    if (text.trim().isEmpty) {
      pill.dismiss();
      if (context.mounted) showToast(context, s.t('noTextLayer'));
      return;
    }
    final stem = p.basenameWithoutExtension(name);
    final docx = buildDocx(text);
    final saved = await scope.library.importBytes(docx, name: '${stem.isEmpty ? 'Document' : stem}.docx', folder: 'convert');
    pill.dismiss();
    if (saved == null || !context.mounted) return;
    await scope.ads.showInterstitial();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SuccessPage(entry: saved, kind: ResultKind.converted, feature: s.t('pdfToWord'), featureKey: 'pdf_to_word')),
    );
  } catch (_) {
    pill.dismiss();
    if (context.mounted) showToast(context, s.t('convertFailed'), warning: true);
  }
}

/// Print PDF: [entry] when given (e.g. the file just converted), otherwise "Select a file" with
/// PDFs and pictures (a picture becomes a PDF first, like the Android app).
Future<void> printPdf(BuildContext context, {DocEntry? entry}) async {
  final scope = AppScope.of(context);
  final target = entry ?? await pickPdfOrImage(context);
  if (target == null || !context.mounted) return;
  scope.guard.arm(scope.settings);
  try {
    final bytes = await File(target.fullPath).readAsBytes();
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: target.name);
  } catch (_) {
    if (context.mounted) showToast(context, S.of(context).t('saveFailed'), warning: true);
  }
}

/// Merge PDF; [entry] (e.g. the open file) starts ticked.
Future<void> openMerge(BuildContext context, {DocEntry? entry}) {
  final preselected = <PdfPick>[
    if (entry != null) PdfPick(path: entry.fullPath, name: entry.name, bytes: entry.bytes, entry: entry, modified: entry.modified),
  ];
  return startMerge(context, preselected: preselected);
}

/// Split PDF; [entry] skips "Select a file".
Future<void> openSplit(BuildContext context, {DocEntry? entry}) {
  final file = entry == null ? null : PdfPick(path: entry.fullPath, name: entry.name, bytes: entry.bytes, entry: entry, modified: entry.modified);
  return startSplit(context, file: file);
}

Future<void> openTemplates(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TemplatesPage()));
}
