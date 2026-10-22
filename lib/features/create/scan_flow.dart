import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app_scope.dart';
import '../../core/settings/app_settings.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/doc_scanner.dart';
import '../../services/image_ops.dart';
import '../../widgets/chrome.dart';
import 'scan_edit_page.dart';
import 'tool_widgets.dart';

/// One page of an Image to PDF / Scan to PDF job. [quad] = crop corners TL, TR, BR, BL as 0..1
/// fractions of the upright source picture (null = no crop); [rotation] is applied after it.
class ScanPage {
  ScanPage({required this.id, required this.source, this.rotation = 0, this.quad, this.filter = ScanFilter.auto});

  final int id;
  String source;
  int rotation;
  List<double>? quad;
  ScanFilter filter;

  /// Finished JPEG made when the editor's Done is pressed, and the [key] it was made from.
  String? output;
  String? outputKey;

  bool get outputReady => output != null && outputKey == key() && File(output!).existsSync();

  String key([ScanFilter? filterOverride]) =>
      '$id:$source:$rotation:${quad?.map((v) => v.toStringAsFixed(3)).join(',')}:${(filterOverride ?? filter).name}';

  ScanPage copy() => ScanPage(id: id, source: source, rotation: rotation, quad: quad == null ? null : List<double>.of(quad!), filter: filter)
    ..output = output
    ..outputKey = outputKey;
}

/// The pages of the job in progress, shared by the editor and the Image to PDF list.
class ScanJob {
  final List<ScanPage> pages = [];
  int _next = 1;

  ScanPage newPage(String source, {List<double>? quad}) => ScanPage(id: _next++, source: source, quad: quad);

  static Future<String> newFile(String prefix) async {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'scan'));
    await dir.create(recursive: true);
    return p.join(dir.path, '${prefix}_${DateTime.now().microsecondsSinceEpoch}.jpg');
  }
}

/// Renders page previews / filter thumbnails in the background and keeps the newest ones.
class ScanRenderer {
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();
  final LinkedHashMap<String, PixelBuf> _sources = LinkedHashMap<String, PixelBuf>();
  final Map<String, Future<Uint8List?>> _running = {};

  static const _maxCache = 40;
  static const _maxSources = 3;

  Uint8List? cached(String key) => _cache[key];

  Future<PixelBuf?> source(String path, int maxPx) async {
    final key = '$path@$maxPx';
    final hit = _sources.remove(key);
    if (hit != null) {
      _sources[key] = hit;
      return hit;
    }
    final buf = await loadPixels(path, maxPx);
    if (buf == null) return null;
    _sources[key] = buf;
    while (_sources.length > _maxSources) {
      _sources.remove(_sources.keys.first);
    }
    return buf;
  }

  void _put(String key, Uint8List bytes) {
    _cache.remove(key);
    _cache[key] = bytes;
    while (_cache.length > _maxCache) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// The page as shown in the editor ([filter] overrides the page's own, e.g. Original to compare).
  Future<Uint8List?> preview(ScanPage page, {ScanFilter? filter}) {
    final key = 'p:${page.key(filter)}';
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    return _running.putIfAbsent(key, () async {
      try {
        final buf = await source(page.source, previewPx);
        if (buf == null) return null;
        final bytes = await _renderIsolated(buf, page.quad, page.rotation, filter ?? page.filter, 85);
        _put(key, bytes);
        return bytes;
      } catch (_) {
        return null;
      } finally {
        _running.remove(key);
      }
    });
  }

  /// Small previews of the page in every filter.
  Future<List<Uint8List>?> thumbs(ScanPage page) {
    final base = 't:${page.key(ScanFilter.original)}';
    if (ScanFilter.values.every((f) => _cache['$base:${f.name}'] != null)) {
      return Future.value([for (final f in ScanFilter.values) _cache['$base:${f.name}']!]);
    }
    final running = _running[base];
    if (running != null) return running.then((_) => thumbs(page));
    final job = () async {
      try {
        final buf = await source(page.source, previewPx);
        if (buf == null) return null;
        final list = await _thumbsIsolated(buf, page.quad, page.rotation);
        for (var i = 0; i < list.length; i++) {
          _put('$base:${ScanFilter.values[i].name}', list[i]);
        }
        return list.first;
      } catch (_) {
        return null;
      } finally {
        _running.remove(base);
      }
    }();
    _running[base] = job;
    return job.then((value) {
      if (value == null) return null;
      final out = <Uint8List>[];
      for (final f in ScanFilter.values) {
        final bytes = _cache['$base:${f.name}'];
        if (bytes == null) return null;
        out.add(bytes);
      }
      return out;
    });
  }

  /// The finished, full-quality page as a JPEG file.
  Future<String?> finalFile(ScanPage page) async {
    if (page.outputReady) return page.output;
    final buf = await loadPixels(page.source, finalPx);
    if (buf == null) return null;
    final bytes = await _renderIsolated(buf, page.quad, page.rotation, page.filter, 90);
    final path = await ScanJob.newFile('page');
    await File(path).writeAsBytes(bytes, flush: true);
    final old = page.output;
    if (old != null && old != path) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    page.output = path;
    page.outputKey = page.key();
    return path;
  }
}

Future<Uint8List> _renderIsolated(PixelBuf buf, List<double>? quad, int rotation, ScanFilter filter, int quality) =>
    Isolate.run(() => renderScanPage(buf, quad: quad, rotation: rotation, filter: filter, quality: quality));

Future<List<Uint8List>> _thumbsIsolated(PixelBuf buf, List<double>? quad, int rotation) =>
    Isolate.run(() => renderFilterThumbs(buf, quad: quad, rotation: rotation));

Future<List<double>?> _detectIsolated(PixelBuf buf) => Isolate.run(() => detectDocument(buf));

/// Document corners for the picture at [path], or null to keep the whole picture.
Future<List<double>?> detectPageEdges(String path) async {
  final buf = await loadPixels(path, 900);
  if (buf == null) return null;
  try {
    return await _detectIsolated(buf);
  } catch (_) {
    return null;
  }
}

/// Document corners of an already loaded picture.
Future<List<double>?> detectPageEdgesIn(PixelBuf buf) async {
  try {
    return await _detectIsolated(buf);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------------------------
// flows
// ---------------------------------------------------------------------------------------------

/// Tools → Image to PDF: "Take a photo / Choose from gallery / Cancel" → page editor.
Future<void> startImageToPdf(BuildContext context) async {
  final job = ScanJob();
  final added = await addScanPages(context, job);
  if (!context.mounted || added.isEmpty) return;
  job.pages.addAll(added);
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanEditPage(job: job)));
}

/// Scan to PDF: the document scanner opens straight away → page editor.
Future<void> startScanToPdf(BuildContext context) async {
  final job = ScanJob();
  final added = await addScanPages(context, job, source: ScanSource.camera);
  if (!context.mounted || added.isEmpty) return;
  job.pages.addAll(added);
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanEditPage(job: job)));
}

enum ScanSource { ask, camera, gallery }

/// "Take a photo / Choose from gallery / Cancel" action sheet (sheet_image_source.xml on a
/// transparent sheet: two 56dp rows in a bg_white_round card, a separate Cancel card, 16sp bold).
Future<ScanSource?> chooseScanSource(BuildContext context) {
  final s = S.of(context);
  return showModalBottomSheet<ScanSource>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheet) {
      final nc = NC.of(sheet);
      Widget row(String label, ScanSource? value, BorderRadius radius) => InkWell(
            borderRadius: radius,
            onTap: () => Navigator.pop(sheet, value),
            child: SizedBox(
              height: 56,
              width: double.infinity,
              child: Center(
                child: Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: nc.textPrimary)),
              ),
            ),
          );
      const top = BorderRadius.vertical(top: Radius.circular(14));
      const bottom = BorderRadius.vertical(bottom: Radius.circular(14));
      final all = BorderRadius.circular(14);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: nc.surface,
                borderRadius: all,
                child: Column(
                  children: [
                    row(s.t('takeAPhoto'), ScanSource.camera, top),
                    Container(height: 0.6, color: nc.surfaceVariant),
                    row(s.t('chooseFromGallery'), ScanSource.gallery, bottom),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Material(color: nc.surface, borderRadius: all, child: row(s.t('cancel'), null, all)),
            ],
          ),
        ),
      );
    },
  );
}

/// New pages from the camera / document scanner or the gallery, cropped as the person chooses.
/// Empty when they back out.
Future<List<ScanPage>> addScanPages(BuildContext context, ScanJob job, {ScanSource source = ScanSource.ask, int maxPages = 50}) async {
  var from = source;
  if (from == ScanSource.ask) {
    final picked = await chooseScanSource(context);
    if (picked == null || !context.mounted) return const [];
    from = picked;
  }
  final scope = AppScope.of(context);
  scope.guard.arm(scope.settings);
  List<String> paths;
  var cropped = false;
  if (from == ScanSource.camera) {
    final shots = await takeDocumentPhotos(maxPages: maxPages);
    if (shots == null) return const [];
    paths = shots.paths;
    cropped = shots.fromScanner;
  } else {
    paths = await pickGalleryImages();
  }
  if (paths.isEmpty || !context.mounted) return const [];
  var autoCrop = false;
  if (!cropped) {
    final choice = await askCropMethod(context);
    if (!context.mounted) return const [];
    autoCrop = choice;
  }
  final pages = <ScanPage>[];
  if (!autoCrop) {
    for (final path in paths) {
      pages.add(job.newPage(path));
    }
    return pages;
  }
  final s = S.of(context);
  final pill = ProgressPill(context)..show(s.t('processingProgress', {'percent': '0'}));
  var missed = false;
  for (var i = 0; i < paths.length; i++) {
    final quad = await detectPageEdges(paths[i]);
    if (quad == null) missed = true;
    pages.add(job.newPage(paths[i], quad: quad));
    pill.show(s.t('processingProgress', {'percent': '${((i + 1) * 100 / paths.length).round()}'}));
  }
  pill.dismiss();
  if (missed && context.mounted) showToast(context, s.t('cropNotFound'));
  return pages;
}

/// "Choose cropping method" (sheet_crop_method.xml): title 20sp bold, hint 14sp, the
/// ill_crop_auto / ill_crop_none picture, Auto crop | No crop checkboxes, OK (52dp bg_apply_btn),
/// "Don't ask again" radio (also in Settings → Scan settings). Starts on No crop; closing the
/// sheet keeps the highlighted choice.
Future<bool> askCropMethod(BuildContext context) async {
  final settings = AppScope.of(context).settings;
  if (settings.scanCrop == ScanCrop.auto) return true;
  if (settings.scanCrop == ScanCrop.none) return false;
  final s = S.of(context);
  var auto = false;
  var dontAsk = false;
  var confirmed = false;
  await showAppSheet<void>(
    context,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) {
        final nc = NC.of(sheet);
        Widget option(bool value, String label) {
          final on = auto == value;
          return Expanded(
            child: InkWell(
              onTap: () => setSheet(() => auto = value),
              child: Row(
                children: [
                  NativeCheckBox(checked: on),
                  const SizedBox(width: 4),
                  Flexible(child: Text(label, style: TextStyle(fontSize: 16, color: nc.textPrimary))),
                ],
              ),
            ),
          );
        }

        final art = auto ? ND.illCropAuto : ND.illCropNone;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.t('chooseCroppingMethod'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                const SizedBox(height: 6),
                Text(s.t('cropMethodHint'), style: TextStyle(color: nc.textSecondary, fontSize: 14)),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return NativeIcon(art, width: width, height: width * art.height / art.width);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    option(true, s.t('autoCrop')),
                    option(false, s.t('noCrop')),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: NativePillButton(
                    height: 52,
                    fontSize: 17,
                    label: s.t('ok'),
                    onPressed: () {
                      confirmed = true;
                      Navigator.pop(sheet);
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: InkWell(
                    onTap: () => setSheet(() => dontAsk = !dontAsk),
                    child: SizedBox(
                      height: 40,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 32,
                            height: 40,
                            child: OverflowBox(
                              maxWidth: 48,
                              maxHeight: 48,
                              child: NativeRadio(checked: dontAsk, offColor: const Color(0xFFB8BEC8)),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(s.t('dontAskAgain'), style: TextStyle(fontSize: 13, color: nc.textSecondary)),
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
    ),
  );
  if (confirmed && dontAsk) await settings.setScanCrop(auto ? ScanCrop.auto : ScanCrop.none);
  return auto;
}
