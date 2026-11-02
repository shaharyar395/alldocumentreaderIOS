import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_shapes.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/chrome.dart';
import '../../widgets/native_art.dart';
import '../../widgets/vector_art.dart';
import 'native_bars.dart';

/// Settings → Add widget, like the Android WidgetSheet: swipe through the four home-screen
/// widgets (Quick tools, Document reader, PDF editor 2x2 and 1x1), dots, "Add to home screen"
/// pins the one shown. iOS: the app's three widgets (ios/ReaderWidget) and how to add them by
/// hand (an app can't place a widget on iOS).
Future<void> showWidgetSheet(BuildContext context) {
  return showAppSheet<void>(context, builder: (_) => const _WidgetSheet());
}

/// The iOS widgets' texts in the app's language, for PlatformBridge.updateWidgetLabels (the keys
/// are the ones ios/ReaderWidget/ReaderWidget.swift reads).
Map<String, String> widgetLabels(S s) => {
      'search': s.t('search'),
      'home': s.t('wHome'),
      'recent': s.t('recent'),
      'bookmarks': s.t('bookmarks'),
      'editPdf': s.t('editPdf'),
      'toolsTitle': s.t('wToolsTitle'),
      'toolsDesc': s.t('wToolsDesc'),
      'readerTitle': s.t('wReaderTitle'),
      'readerDesc': s.t('wReaderDesc'),
      'editorTitle': s.t('wEditorTitle'),
      'editorDesc': s.t('wEditorDesc'),
    };

/// (kind for PlatformBridge.pinWidget, title key, description key, preview size)
const _widgets = [
  ('tools', 'wToolsTitle', 'wToolsDesc', Size(270, 110)),
  ('reader', 'wReaderTitle', 'wReaderDesc', Size(270, 110)),
  ('editor2x2', 'wEditorTitle', 'wEditorDesc', Size(128, 128)),
  ('editor1x1', 'wEditorTitle', 'wEditorDesc', Size(76, 76)),
];

/// The iOS widgets (ios/ReaderWidget): Quick tools and Document reader (medium), PDF editor (small).
const _iosWidgets = [
  ('tools', 'wToolsTitle', 'wToolsDesc', Size(292, 136)),
  ('reader', 'wReaderTitle', 'wReaderDesc', Size(292, 136)),
  ('editor', 'wEditorTitle', 'wEditorDesc', Size(136, 136)),
];

class _WidgetSheet extends StatefulWidget {
  const _WidgetSheet();

  @override
  State<_WidgetSheet> createState() => _WidgetSheetState();
}

class _WidgetSheetState extends State<_WidgetSheet> {
  final _pager = PageController();
  int _page = 0;
  bool _busy = false;

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final s = S.of(context);
    if (!Platform.isAndroid) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    final ok = await PlatformBridge.pinWidget(_widgets[_page].$1);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.pop(context);
    } else {
      showToast(context, s.t('widgetManualHint'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final ios = !Platform.isAndroid;
    final list = ios ? _iosWidgets : _widgets;
    final count = list.length;
    final current = list[_page.clamp(0, count - 1)];
    // sheet_add_widget.xml
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 24, 56, 0),
                child: Column(
                  children: [
                    Text(
                      s.t(current.$2),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: nc.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      ios ? '${s.t(current.$3)}\n${s.t('widgetIosHint')}' : s.t(current.$3),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: nc.textSecondary),
                    ),
                  ],
                ),
              ),
              PositionedDirectional(
                top: 6,
                end: 6,
                // btnClose: 40dp, padding 11dp, ic_close tinted text_hint
                child: NativeIconButton(
                  icon: ND.icClose,
                  size: 40,
                  padding: 11,
                  tint: nc.textHint,
                  tooltip: s.t('cancel'),
                  onTap: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 170,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: PageView.builder(
                controller: _pager,
                clipBehavior: Clip.none,
                itemCount: count,
                onPageChanged: (value) => setState(() => _page = value),
                itemBuilder: (context, index) {
                  final widgetInfo = list[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: DecoratedBox(
                      // bg_widget_stage
                      decoration: NS.bgWidgetStage(context),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: ios
                                ? IosWidgetPreview(kind: widgetInfo.$1, size: widgetInfo.$4)
                                : WidgetPreview(kind: widgetInfo.$1, size: widgetInfo.$4),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (count > 1) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < count; i++)
                  Container(
                    width: i == _page ? 14 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: i == _page ? nc.primary : const Color(0xFFD5DAE1),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: NativeApplyButton(
              label: ios ? s.t('ok') : s.t('addWidgetButton'),
              fontSize: 16,
              onTap: _busy ? null : _add,
            ),
          ),
        ],
      ),
    );
  }
}

/// The look of an Android home-screen widget (res/layout/tools_widget.xml, reader_widget.xml,
/// pdf_editor_widget.xml, pdf_editor_small_widget.xml), drawn in Flutter.
class WidgetPreview extends StatelessWidget {
  const WidgetPreview({super.key, required this.kind, required this.size});

  final String kind;
  final Size size;

  static const _ink = Color(0xFF1B1F2A);
  static const _grey = Color(0xFF8E949E);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final small = kind == 'editor1x1';
    final Widget content = switch (kind) {
      'tools' => Column(
          children: [
            _topRow(s, editPill: false),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                children: [
                  _button(NativeArt.wHome, NativeArt.wHomeViewport, s.t('wHome')),
                  _button(NativeArt.wRecent, NativeArt.wRecentViewport, s.t('recent')),
                  _button(NativeArt.wBookmark, NativeArt.wBookmarkViewport, s.t('bookmarks')),
                  _button(NativeArt.wEditTile, NativeArt.wEditTileViewport, s.t('editPdf')),
                ],
              ),
            ),
          ],
        ),
      'reader' => Column(
          children: [
            _topRow(s, editPill: true),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                children: [
                  _button(NativeArt.catPdf, NativeArt.catPdfViewport, 'PDF'),
                  _button(NativeArt.catWord, NativeArt.catWordViewport, 'Word'),
                  _button(NativeArt.catExcel, NativeArt.catExcelViewport, 'Excel'),
                  _button(NativeArt.catPpt, NativeArt.catPptViewport, 'PPT'),
                ],
              ),
            ),
          ],
        ),
      'editor2x2' => Stack(
          children: [
            const Positioned.fill(
              bottom: 22,
              child: VectorArt(NativeArt.wEditorArt, viewport: NativeArt.wEditorArtViewport, width: 104, height: 82),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.t('editPdf'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const VectorArt(NativeArt.wArrow, viewport: NativeArt.wArrowViewport, width: 20, height: 20),
                ],
              ),
            ),
          ],
        ),
      _ => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const VectorArt(NativeArt.wEditRed, viewport: NativeArt.wEditRedViewport, width: 36, height: 36),
            const SizedBox(height: 3),
            Text(
              s.t('editPdf'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _ink, fontSize: 11),
            ),
          ],
        ),
    };
    // bg_widget, elevation 3
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(18),
      color: Colors.white,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF4F8FF), Color(0xFFFFFFFF)],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.all(small ? 6 : (kind == 'editor2x2' ? 12 : 10)),
            // the home screen is not part of the app's theme or text direction
            child: MediaQuery.withNoTextScaling(
              child: Directionality(textDirection: TextDirection.ltr, child: content),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topRow(S s, {required bool editPill}) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: _pill(
              Row(
                children: [
                  const VectorArt(NativeArt.wSearch, viewport: NativeArt.wSearchViewport, width: 16, height: 16),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(s.t('search'), maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(color: _grey, fontSize: 13)),
                  ),
                ],
              ),
              end: 0,
            ),
          ),
          if (editPill) ...[
            const SizedBox(width: 8),
            _pill(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const VectorArt(NativeArt.wEdit, viewport: NativeArt.wEditViewport, width: 16, height: 16),
                  const SizedBox(width: 6),
                  Text(s.t('editPdf'), maxLines: 1, style: const TextStyle(color: _ink, fontSize: 13)),
                ],
              ),
              end: 12,
            ),
          ],
        ],
      ),
    );
  }

  /// bg_widget_pill: white, thin blue-grey border, round.
  Widget _pill(Widget child, {required double end}) {
    return Container(
      padding: EdgeInsets.only(left: 12, right: end),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E7F2)),
      ),
      child: child,
    );
  }

  Widget _button(List<VPath> icon, Size viewport, String label) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          VectorArt(icon, viewport: viewport, width: 28, height: 28),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ink, fontSize: 11)),
        ],
      ),
    );
  }
}

/// The look of the iOS widgets (ios/ReaderWidget/ReaderWidget.swift), drawn in Flutter with the
/// same colours; Material icons stand in for the SF Symbols.
class IosWidgetPreview extends StatelessWidget {
  const IosWidgetPreview({super.key, required this.kind, required this.size});

  final String kind;
  final Size size;

  static const _ink = Color(0xFF1B1F2A);
  static const _grey = Color(0xFF8E949E);
  static const _border = Color(0xFFE1E7F2);
  static const _edit = Color(0xFFE53935);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final Widget content = switch (kind) {
      'tools' => Column(
          children: [
            _search(s),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                children: [
                  _button(Icons.home_rounded, const Color(0xFF1E6FE6), s.t('wHome')),
                  _button(Icons.access_time_filled_rounded, const Color(0xFF1FB35A), s.t('recent')),
                  _button(Icons.bookmark_rounded, const Color(0xFFFFA000), s.t('bookmarks')),
                  _button(Icons.edit_square, _edit, s.t('editPdf'), tile: true),
                ],
              ),
            ),
          ],
        ),
      'reader' => Column(
          children: [
            Row(
              children: [
                Expanded(child: _search(s)),
                const SizedBox(width: 8),
                _pill(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.edit_rounded, size: 15, color: _edit),
                      const SizedBox(width: 6),
                      Text(s.t('editPdf'), maxLines: 1, style: const TextStyle(color: _ink, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                children: [
                  _button(Icons.picture_as_pdf_rounded, const Color(0xFFD10000), 'PDF', tile: true),
                  _button(Icons.description_rounded, const Color(0xFF1560D6), 'Word', tile: true),
                  _button(Icons.table_chart_rounded, const Color(0xFF008A3B), 'Excel', tile: true),
                  _button(Icons.slideshow_rounded, const Color(0xFFF26201), 'PPT', tile: true),
                ],
              ),
            ),
          ],
        ),
      _ => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _border),
                ),
                child: Stack(
                  children: [
                    const Center(child: Icon(Icons.picture_as_pdf_outlined, size: 38, color: Color(0xFFD10000))),
                    PositionedDirectional(
                      end: 6,
                      bottom: 6,
                      child: Container(
                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: const Icon(Icons.edit_rounded, size: 22, color: _edit),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.t('editPdf'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                const Icon(Icons.arrow_circle_right_rounded, size: 20, color: Color(0xFF1E6FE6)),
              ],
            ),
          ],
        ),
    };
    // an iOS widget: 22 pt corners, the light blue-to-white background
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(22),
      color: Colors.white,
      child: Container(
        width: size.width,
        height: size.height,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF4F8FF), Color(0xFFFFFFFF)],
          ),
        ),
        // the home screen is not part of the app's theme or text direction
        child: MediaQuery.withNoTextScaling(
          child: Directionality(textDirection: TextDirection.ltr, child: content),
        ),
      ),
    );
  }

  Widget _search(S s) {
    return _pill(
      Row(
        children: [
          const Icon(Icons.search_rounded, size: 16, color: _grey),
          const SizedBox(width: 8),
          Flexible(
            child: Text(s.t('search'), maxLines: 1, overflow: TextOverflow.clip, style: const TextStyle(color: _grey, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// White capsule with a thin blue-grey border, 34 pt tall.
  Widget _pill(Widget child) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }

  Widget _button(IconData icon, Color tint, String label, {bool tile = false}) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (tile)
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(7)),
              child: Icon(icon, size: 16, color: Colors.white),
            )
          else
            SizedBox(width: 28, height: 28, child: Icon(icon, size: 24, color: tint)),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ink, fontSize: 11)),
        ],
      ),
    );
  }
}
