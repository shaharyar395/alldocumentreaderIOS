import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart' show MiddleEllipsisText;
import '../create/success_page.dart';
import '../create/tool_widgets.dart' hide NativeIconButton;
import '../files/file_actions.dart';
import '../settings/native_bars.dart';

/// Pictures (JPG, PNG …): pinch / double-tap zoom, tap to hide the bars, Convert to PDF,
/// bookmark, share and the ⋮ menu — like the Android ImageViewerActivity.
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.entry});

  final DocEntry entry;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late DocEntry _entry = widget.entry;
  final _zoom = TransformationController();
  Offset _tapAt = Offset.zero;
  bool _chrome = true;
  bool _barsHidden = false;
  bool _converting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = AppScope.of(context).library;
    for (final entry in library.entries) {
      if (entry.id == _entry.id) {
        _entry = entry;
        break;
      }
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    if (_barsHidden) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    _barsHidden = !_chrome;
    if (_chrome) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: const [SystemUiOverlay.bottom]);
    }
  }

  void _toggleZoom() {
    if (_zoom.value.getMaxScaleOnAxis() > 1.2) {
      _zoom.value = Matrix4.identity();
      return;
    }
    const scale = 2.5;
    _zoom.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(-_tapAt.dx * (scale - 1), -_tapAt.dy * (scale - 1), 0);
  }

  /// Convert to PDF → "Converting… (x%)" → Converted successfully (like the other converters).
  Future<void> _convert() async {
    if (_converting) return;
    final s = S.of(context);
    final scope = AppScope.of(context);
    final name = _entry.name;
    setState(() => _converting = true);
    final pill = ProgressPill(context)..show(s.t('convertingProgress', {'percent': '0'}));
    DocEntry? saved;
    try {
      final bytes = await File(_entry.fullPath).readAsBytes();
      final pdf = await imagesToPdf(
        [bytes],
        onProgress: (value) => pill.show(s.t('convertingProgress', {'percent': '${(value * 100).clamp(0, 99).round()}'})),
      );
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      saved = await scope.library.importBytes(pdf, name: '$stem.pdf', folder: 'convert');
    } catch (_) {
      saved = null;
    }
    pill.dismiss();
    if (!mounted) return;
    setState(() => _converting = false);
    final result = saved;
    if (result == null) {
      showToast(context, s.t('convertFailed'));
      return;
    }
    await scope.ads.showInterstitial();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SuccessPage(entry: result, kind: ResultKind.converted, feature: s.t('imageToPdf'), featureKey: 'image_to_pdf'),
      ),
    );
  }

  /// ⋮: the file menu (Share, Rename, To home screen, Save to Drive, Delete), like the Android
  /// ImageViewerActivity; the viewer closes when the picture was deleted.
  Future<void> _menu() async {
    final library = AppScope.of(context).library;
    await showFileMenu(context, _entry);
    if (!mounted) return;
    final current = library.entries.cast<DocEntry?>().firstWhere((e) => e?.id == _entry.id, orElse: () => null);
    if (current == null || current.inBin || !File(current.fullPath).existsSync()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _entry = current);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final file = File(_entry.fullPath);
    // activity_image_viewer.xml: @color/surface_variant behind the picture, a 56dp
    // @color/surface bar (elevation 2dp): back, name, bookmark, share, convert, ⋮
    return Scaffold(
      backgroundColor: nc.surfaceVariant,
      body: SafeArea(
        top: !_chrome,
        child: Column(
          children: [
            if (_chrome)
              Material(
                color: nc.surface,
                elevation: 2,
                child: SafeArea(
                  bottom: false,
                  left: false,
                  right: false,
                  child: SizedBox(
                    height: 56,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          const NativeBackButton(),
                          Expanded(
                            child: MiddleEllipsisText(
                              _entry.name,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary),
                            ),
                          ),
                          NativeIconButton(
                            icon: _entry.bookmarked ? ND.icBookmark : ND.icBookmarkBorder,
                            tint: nc.textPrimary,
                            tooltip: _entry.bookmarked ? s.t('removeBookmark') : s.t('bookmark'),
                            onTap: () => toggleBookmarkWithPill(context, _entry),
                          ),
                          NativeIconButton(
                            icon: ND.icShare,
                            tint: nc.textPrimary,
                            tooltip: s.t('share'),
                            onTap: () => shareEntry(context, _entry),
                          ),
                          if (_converting)
                            SizedBox(
                              width: 44,
                              height: 44,
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: nc.primary),
                                ),
                              ),
                            )
                          else
                            NativeIconButton(
                              icon: ND.icConvertPdf,
                              tint: nc.textPrimary,
                              tooltip: s.t('convertToPdf'),
                              onTap: _convert,
                            ),
                          NativeIconButton(icon: ND.icMoreVert, tint: nc.textPrimary, onTap: _menu),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: GestureDetector(
                onTap: _toggleChrome,
                onDoubleTapDown: (details) => _tapAt = details.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: 6,
                  child: SizedBox.expand(
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => Center(
                        child: Text(s.t('unsupportedFile'), style: TextStyle(color: nc.textPrimary, fontSize: 15)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const BannerSlot(unit: 2),
          ],
        ),
      ),
    );
  }
}
