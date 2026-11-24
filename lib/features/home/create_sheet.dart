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
import '../../services/app_analytics.dart';
import '../../services/ocr_service.dart';
import '../../services/ios_analytics.dart';
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

/// The "+" sheet, like the Android sheet_create_files ("Plum deck" 1.0.35+): handle, "Create
/// files" with Import files, Use templates and Create PDF cards (soft surface_variant cards, 18 dp
/// corners, 60 dp) and "Convert format" with Image to PDF, Scan to PDF, Word to PDF, PDF to Word
/// and PPT to PDF tiles. Every icon is an outlined circle (2 dp ring on the card colour) with the
/// glyph in the format's colour; the circles pop in one after another. On Android every item
/// needs file access first; iOS needs none (ensureAccess / needsAccessGate).
Future<void> showCreateSheet(BuildContext context) {
  final s = S.of(context);
  final nc = NC.of(context);
  // (icon, colour, label, Android string name, action)
  final cards = <(NDrawable, Color, String, String, Future<void> Function())>[
    (ND.icCreateImport, nc.typeAll, s.t('importFiles'), 'import_files', () => importFiles(context)),
    (ND.icCreateTemplates, nc.typeTxt, s.t('useTemplates'), 'use_templates', () => openTemplates(context)),
    (ND.icCreatePdfBadge, nc.typePdf, s.t('createPdf'), 'create_pdf', () => createBlankPdf(context)),
  ];
  final tiles = <(NDrawable, Color, String, String, Future<void> Function())>[
    (ND.icCvImage2pdf, nc.typeImage, s.t('imageToPdf'), 'image_to_pdf', () => imageToPdfFromList(context)),
    (ND.icCvScan, nc.typeExcel, s.t('scanToPdf'), 'scan_to_pdf', () => pickImages(context, camera: true)),
    (ND.icCvWord2pdf, nc.typeWord, s.t('wordToPdf'), 'word_to_pdf', () => convertOffice(context, slides: false)),
    (ND.icCvPdf2word, nc.typePdf, s.t('pdfToWord'), 'pdf_to_word', () => convertPdfToWord(context)),
    (ND.icCvPpt2pdf, nc.typePpt, s.t('pptToPdf'), 'ppt_to_pdf', () => convertOffice(context, slides: true)),
  ];
  return showAppSheet<void>(
    context,
    builder: (sheet) {
      final c = NC.of(sheet);
      final still = MediaQuery.maybeDisableAnimationsOf(sheet) ?? false;
      void run(String item, Future<void> Function() action) {
        logEvent('create_tap', {'item': item});
        logEvent('create_${item}_tapped');
        Navigator.pop(sheet);
        ensureAccess(context).then((ok) {
          if (ok && context.mounted) action();
        });
      }

      // the outlined circle; [order] staggers its pop-in
      Widget ring(NDrawable icon, Color color, double size, double glyph, int order) {
        final circle = Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
          child: NativeIcon(icon, size: glyph, tint: color),
        );
        if (still) return circle;
        final delay = 40 * order;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 300 + delay),
          curve: Interval(delay / (300 + delay), 1, curve: Curves.easeOutBack),
          builder: (context, v, child) => Transform.scale(scale: 0.8 + 0.2 * v, child: Opacity(opacity: v.clamp(0.0, 1.0), child: child)),
          child: circle,
        );
      }

      // item_create_card: 60 dp ds_a_sheet_tile (surface_variant, 18 dp corners), a 40 dp ring with
      // a 20 dp glyph, 14 sp medium label; 5 dp margin
      Widget card((NDrawable, Color, String, String, Future<void> Function()) item, int order) {
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Material(
              color: c.surfaceVariant,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                splashColor: c.rowPressed,
                onTap: () => run(item.$4, item.$5),
                child: SizedBox(
                  height: 60,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 10, end: 8),
                    child: Row(
                      children: [
                        ring(item.$1, item.$2, 40, 20, order),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            item.$3,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.textPrimary),
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

      // item_convert_tile: a 52 dp frame with a 48 dp ring and a 22 dp glyph, the 12 sp label 6 dp
      // below; 4 dp top / 8 dp bottom padding
      Widget tile((NDrawable, Color, String, String, Future<void> Function())? item, int order) {
        if (item == null) return const Expanded(child: SizedBox.shrink());
        return Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              splashColor: c.rowPressed,
              onTap: () => run(item.$4, item.$5),
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 52, height: 52, child: Center(child: ring(item.$1, item.$2, 48, 22, order))),
                    const SizedBox(height: 6),
                    Text(
                      item.$3,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.textPrimary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6, top: 8, bottom: 6),
                child: Text(s.t('createFiles'), style: sheetTitle(sheet)),
              ),
              Row(children: [card(cards[0], 0), card(cards[1], 1)]),
              Row(children: [card(cards[2], 2), const Expanded(child: SizedBox.shrink())]),
              DsSectionLabel(s.t('convertFormat'), padding: const EdgeInsetsDirectional.only(start: 6, top: 16, bottom: 8)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [tile(tiles[0], 3), tile(tiles[1], 4), tile(tiles[2], 5), tile(tiles[3], 6)],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [tile(tiles[4], 7), tile(null, 0), tile(null, 0), tile(null, 0)],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// SheetTitle: 18 sp medium text_primary.
TextStyle sheetTitle(BuildContext context) =>
    TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: NC.of(context).textPrimary);

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
  logEvent(camera ? 'scan_camera_tapped' : 'scan_gallery_tapped');
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
  job.imageToPdf = true;
  job.fromGallery = true;
  job.pages.add(job.newPage(pick.path));
  IosAnalytics.log('image_choosed_from_galary');
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
      analyticsScreen: slides ? 'ppt_to_pdf' : 'word_to_pdf',
    );
    if (pick == null) return;
    path = pick.path;
    name = pick.name;
  }
  if (!context.mounted) return;
  final screen = slides ? 'ppt_to_pdf' : 'word_to_pdf';
  IosAnalytics.activate(screen);
  IosAnalytics.log('${screen}_file_selected', {'file_type': slides ? 'ppt' : 'word', 'screen': screen});
  IosAnalytics.log('convert_button_tapped', {'screen': screen});
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
    IosAnalytics.converted(slides ? 'ppt' : 'word', 'pdf');
    IosAnalytics.left(screen);
    await scope.ads.showInterstitial(unit: 2, honorCooldown: true);
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
    IosAnalytics.appError(slides ? 'ppt_to_pdf' : 'word_to_pdf', 'convert_failed');
    if (context.mounted) showToast(context, s.t('convertFailed'), warning: true);
  }
}

Future<void> convertPdfToWord(BuildContext context, {DocEntry? entry}) async {
  final s = S.of(context);
  final scope = AppScope.of(context);
  String? path = entry?.fullPath;
  var name = entry?.name ?? 'Document.pdf';
  if (path == null) {
    final pick = await pickOnePdf(context, analyticsScreen: 'pdf_to_word');
    if (pick == null) return;
    path = pick.path;
    name = pick.name;
  }
  if (!context.mounted) return;
  IosAnalytics.activate('pdf_to_word');
  IosAnalytics.log('pdf_to_word_file_selected', {'file_type': 'pdf', 'screen': 'pdf_to_word'});
  IosAnalytics.log('convert_button_tapped', {'screen': 'pdf_to_word'});
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
    IosAnalytics.converted('pdf', 'word');
    IosAnalytics.left('pdf_to_word');
    await scope.ads.showInterstitial(unit: 2, honorCooldown: true);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SuccessPage(entry: saved, kind: ResultKind.converted, feature: s.t('pdfToWord'), featureKey: 'pdf_to_word')),
    );
  } catch (_) {
    pill.dismiss();
    IosAnalytics.appError('pdf_to_word', 'convert_failed');
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
