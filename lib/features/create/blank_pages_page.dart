import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/image_ops.dart';
import '../../services/pdf_tools.dart';
import '../../widgets/chrome.dart';
import 'success_page.dart';
import 'tool_widgets.dart';

/// New blank pages: [style] on a [width] × [height] point page in [color], [count] times.
class BlankSpec {
  const BlankSpec({required this.style, required this.width, required this.height, required this.color, required this.count});

  final BlankStyle style;
  final double width;
  final double height;
  final int color;
  final int count;

  PdfPageFormat get format => PdfPageFormat(width, height);
}

/// Page colours offered for blank pages (like the Android app).
const blankColors = <int>[0xFFFFFFFF, 0xFFEDEEF0, 0xFFE3EEFB, 0xFFFCE3E3, 0xFFFFF4D0, 0xFFE2F3E5];

String blankStyleLabel(S s, BlankStyle style) {
  return switch (style) {
    BlankStyle.blank => s.t('styleBlank'),
    BlankStyle.line => s.t('styleLine'),
    BlankStyle.notebook => s.t('notebook'),
    BlankStyle.cornell => s.t('cornell'),
    BlankStyle.grid => s.t('styleGrid'),
    BlankStyle.graph => s.t('graph'),
  };
}

/// "AllDocReader_10151620" like the Android app.
String defaultDocName() {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'AllDocReader_${two(now.month)}${two(now.day)}${two(now.hour)}${two(now.minute)}';
}

/// Create PDF (+ sheet / Tools) and Manage pages → Insert → Blank pages: template, page size
/// (A5 … Legal, A3, B5, B4, "Follow previous"), page colour, orientation and count; Create PDF also
/// asks for the file name.
class BlankPagesPage extends StatefulWidget {
  const BlankPagesPage({super.key, this.createMode = false, this.previousWidth, this.previousHeight});

  /// true = Create PDF (saves a new file); false = returns a [BlankSpec] for Insert.
  final bool createMode;

  /// Size of the page before the insert point ("Follow previous").
  final double? previousWidth;
  final double? previousHeight;

  @override
  State<BlankPagesPage> createState() => _BlankPagesPageState();
}

class _BlankPagesPageState extends State<BlankPagesPage> {
  BlankStyle _style = BlankStyle.blank;
  PaperSize? _size = PaperSize.a4;
  bool _landscape = false;
  int _color = blankColors.first;
  int _count = 1;
  String _name = defaultDocName();
  bool _busy = false;
  double? _prevW;
  double? _prevH;

  static const _maxCount = 200;

  @override
  void initState() {
    super.initState();
    _prevW = widget.previousWidth;
    _prevH = widget.previousHeight;
    if (!widget.createMode && _prevW != null) {
      _size = null;
      _landscape = (_prevW ?? 0) > (_prevH ?? 0);
    }
    if (widget.createMode) {
      SharedPreferences.getInstance().then((prefs) {
        final w = prefs.getDouble('create_prev_w');
        final h = prefs.getDouble('create_prev_h');
        if (!mounted || w == null || h == null) return;
        setState(() {
          _prevW = w;
          _prevH = h;
        });
      });
    }
  }

  (double, double) get _dims {
    double w;
    double h;
    final size = _size;
    if (size == null && _prevW != null && _prevH != null) {
      w = _prevW!;
      h = _prevH!;
    } else {
      final base = paperBase(size ?? PaperSize.a4);
      w = base.width;
      h = base.height;
    }
    if ((w > h) != _landscape) {
      final t = w;
      w = h;
      h = t;
    }
    return (w, h);
  }

  String _sizeLabel(S s, PaperSize? size) => size == null ? s.t('followPrevious') : paperLabel(size);

  String _mm(double points) => (points / PdfPageFormat.mm).round().toString();

  /// sheet_page_size.xml: "Page size" with ×, the sizes as 4-column cards (mini page in the real
  /// proportions, name 11sp bold, "148x210mm" 10sp), Apply.
  Future<void> _chooseSize() async {
    final s = S.of(context);
    final options = <PaperSize?>[if (_prevW != null) null, ...PaperSize.values];
    PaperSize? chosen = _size;
    final picked = await showAppSheet<(bool, PaperSize?)>(
      context,
      builder: (sheet) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          final nc = NC.of(sheetContext);
          Widget card(PaperSize? option) {
            final on = option == chosen;
            final w = option == null ? _prevW! : paperBase(option).width;
            final h = option == null ? _prevH! : paperBase(option).height;
            final pageText = Text(
              _sizeLabel(s, option),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: on ? nc.primary : nc.textPrimary),
            );
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setSheet(() => chosen = option),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    children: [
                      Container(
                        height: 68,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: nc.surfaceVariant, borderRadius: BorderRadius.circular(8)),
                        child: option == null
                            ? Padding(padding: const EdgeInsets.all(4), child: pageText)
                            : Container(
                                height: 46,
                                width: 46 * math.min(w, h) / math.max(w, h),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(2),
                                  border: on ? Border.all(color: nc.primary, width: 1.5) : null,
                                ),
                                child: FittedBox(fit: BoxFit.scaleDown, child: pageText),
                              ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_mm(math.min(w, h))}x${_mm(math.max(w, h))}mm',
                        style: TextStyle(fontSize: 10, color: nc.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          final rows = <Widget>[];
          for (var i = 0; i < options.length; i += 4) {
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var j = i; j < i + 4; j++) j < options.length ? card(options[j]) : const Expanded(child: SizedBox()),
                ],
              ),
            );
          }
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(s.t('pageSize'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                        ),
                        NativeIconButton(
                          ND.icClose,
                          size: 40,
                          padding: 11,
                          tint: nc.textSecondary,
                          tooltip: s.t('cancel'),
                          onPressed: () => Navigator.pop(sheet),
                        ),
                      ],
                    ),
                  ),
                  ...rows,
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: NativePillButton(label: s.t('apply'), onPressed: () => Navigator.pop(sheet, (true, chosen))),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _size = picked.$2;
      if (_size == null && _prevW != null) _landscape = (_prevW ?? 0) > (_prevH ?? 0);
    });
  }

  Future<void> _submit() async {
    final (w, h) = _dims;
    final spec = BlankSpec(style: _style, width: w, height: h, color: _color, count: _count);
    if (!widget.createMode) {
      Navigator.of(context).pop(spec);
      return;
    }
    setState(() => _busy = true);
    final s = S.of(context);
    final scope = AppScope.of(context);
    final pill = ProgressPill(context)..show(s.t('saving'));
    try {
      final bytes = await blankPdf(pages: _count, style: _style, format: spec.format, background: PdfColor.fromInt(_color));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('create_prev_w', w);
      await prefs.setDouble('create_prev_h', h);
      final entry = await scope.library.importBytes(bytes, name: '${safeFileName(_name)}.pdf', folder: 'create');
      pill.dismiss();
      if (!mounted) return;
      if (entry == null) throw StateError('save');
      await scope.ads.showInterstitial(unit: 2);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => SuccessPage(entry: entry, kind: ResultKind.created, feature: s.t('createPdf'), featureKey: 'create_pdf')),
      );
    } catch (_) {
      pill.dismiss();
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, s.t('saveFailed'), warning: true);
    }
  }

  static NDrawable _styleIcon(BlankStyle style) {
    return switch (style) {
      BlankStyle.blank => ND.icTplBlank,
      BlankStyle.line => ND.icTplLine1,
      BlankStyle.notebook => ND.icTplNotebook,
      BlankStyle.cornell => ND.icTplCornell,
      BlankStyle.grid => ND.icTplGrid,
      BlankStyle.graph => ND.icTplGraph,
    };
  }

  void _pickStyle(BlankStyle style) {
    setState(() => _style = style);
    final page = BlankStyle.values.indexOf(style);
    if (_pager.hasClients && (_pager.page ?? 0).round() != page) {
      _pager.animateToPage(page, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  /// ViewPager2 with 100dp padding on both sides: each page is the screen width minus 200dp.
  late final PageController _pager = PageController(
    initialPage: BlankStyle.values.indexOf(_style),
    viewportFraction: () {
      final width = MediaQuery.sizeOf(context).width;
      return width > 260 ? (width - 200) / width : 0.5;
    }(),
  );

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final (w, h) = _dims;
    final styles = BlankStyle.values;
    return Scaffold(
      backgroundColor: nc.surfaceVariant,
      appBar: NativeTopBar(
        title: widget.createMode ? s.t('createPdf') : s.t('insertBlankPages'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                const SizedBox(height: 16),
                // ViewPager2 250dp with 100dp side padding; side pages scale 0.88 and fade to 0.7
                SizedBox(
                  height: 250,
                  child: Builder(
                    builder: (context) {
                      return PageView.builder(
                        controller: _pager,
                        itemCount: styles.length,
                        padEnds: true,
                        onPageChanged: (index) => setState(() => _style = styles[index]),
                        itemBuilder: (context, index) {
                          return AnimatedBuilder(
                            animation: _pager,
                            builder: (context, child) {
                              final current = _pager.hasClients && _pager.position.haveDimensions
                                  ? (_pager.page ?? index.toDouble())
                                  : styles.indexOf(_style).toDouble();
                              final distance = (current - index).abs().clamp(0.0, 1.0);
                              return Opacity(
                                opacity: 1 - 0.3 * distance,
                                child: Transform.scale(scale: 1 - 0.12 * distance, child: child),
                              );
                            },
                            child: GestureDetector(
                              onTap: () => _pickStyle(styles[index]),
                              child: Center(child: _preview(s, styles[index], w, h)),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                // strip: bg_strip (white, 10dp), 44dp, the template icons (30 x 34, selected bg_strip_selected)
                Center(
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final style in styles)
                          Tooltip(
                            message: blankStyleLabel(s, style),
                            child: GestureDetector(
                              onTap: () => _pickStyle(style),
                              child: Container(
                                width: 30,
                                height: 34,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                padding: const EdgeInsets.all(3),
                                decoration: style == _style
                                    ? BoxDecoration(
                                        color: nc.surfaceVariant,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: nc.primary, width: 1.5),
                                      )
                                    : null,
                                child: NativeIcon(_styleIcon(style)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  color: nc.surface,
                  padding: const EdgeInsetsDirectional.only(start: 16, end: 12),
                  child: Column(
                    children: [
                      if (widget.createMode)
                        _row(
                          nc,
                          s.t('nameHint'),
                          Text(
                            '$_name.pdf',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: TextStyle(fontSize: 14, color: nc.textSecondary),
                          ),
                          () async {
                            final next = await askText(context, title: s.t('nameHint'), initial: _name, hint: s.t('nameHint'));
                            if (next != null && mounted) setState(() => _name = safeFileName(next));
                          },
                        ),
                      _row(nc, s.t('pageSize'), Text(_sizeLabel(s, _size), style: TextStyle(fontSize: 14, color: nc.textSecondary)), _chooseSize),
                      _row(
                        nc,
                        s.t('pageColor'),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final color in blankColors)
                              GestureDetector(
                                onTap: () => setState(() => _color = color),
                                child: Container(
                                  width: 26,
                                  height: 26,
                                  margin: const EdgeInsetsDirectional.only(start: 10),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: Color(color),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFFD5DAE1)),
                                  ),
                                  child: _color == color ? const NativeIcon(ND.icCheck, size: 16, tint: Color(0xFF1B1F2A)) : null,
                                ),
                              ),
                          ],
                        ),
                        null,
                      ),
                      _row(
                        nc,
                        s.t('orientation'),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            NativeIconButton(
                              ND.icOrientPortrait,
                              size: 40,
                              padding: 9,
                              tint: _landscape ? nc.textPrimary : nc.primary,
                              tooltip: s.t('portrait'),
                              onPressed: () => setState(() => _landscape = false),
                            ),
                            NativeIconButton(
                              ND.icOrientLandscape,
                              size: 40,
                              padding: 9,
                              tint: _landscape ? nc.primary : nc.textPrimary,
                              tooltip: s.t('landscape'),
                              onPressed: () => setState(() => _landscape = true),
                            ),
                          ],
                        ),
                        null,
                      ),
                      _row(
                        nc,
                        s.t('pageCount'),
                        Container(
                          height: 32,
                          decoration: BoxDecoration(color: nc.surfaceVariant, borderRadius: BorderRadius.circular(16)),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _stepButton(ND.icMinus, _count > 1, () => setState(() => _count--)),
                              Material(
                                type: MaterialType.transparency,
                                child: InkWell(
                                  onTap: () async {
                                    final value = await askNumber(context, title: s.t('pageCount'), initial: _count, min: 1, max: _maxCount);
                                    if (value != null && mounted) setState(() => _count = value);
                                  },
                                  child: SizedBox(
                                    width: 36,
                                    height: 32,
                                    child: Center(child: Text('$_count', style: TextStyle(fontSize: 15, color: nc.textPrimary))),
                                  ),
                                ),
                              ),
                              _stepButton(ND.icAdd, _count < _maxCount, () => setState(() => _count++)),
                            ],
                          ),
                        ),
                        null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: NativePillButton(
                  height: 50,
                  label: widget.createMode ? s.t('create') : s.t('insert'),
                  onPressed: _busy ? null : _submit,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// TemplatePreviewView: the ruling on the page colour, elevation 2, the template name (15sp bold
  /// #1B1F2A) and "210x297mm" (11sp #8E949E) in the middle.
  Widget _preview(S s, BlankStyle style, double w, double h) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var height = constraints.maxHeight;
        var width = height * w / h;
        if (width > constraints.maxWidth) {
          width = constraints.maxWidth;
          height = width * h / w;
        }
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Color(_color),
            boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 3, offset: Offset(0, 1))],
          ),
          child: CustomPaint(
            painter: PaperPainter(style),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    blankStyleLabel(s, style),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1B1F2A)),
                  ),
                  const SizedBox(height: 2),
                  Text('${_mm(w)}x${_mm(h)}mm', style: const TextStyle(fontSize: 11, color: Color(0xFF8E949E))),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 32dp stepper button, tint @color/tool_tint (#C3C8D0 when disabled).
  Widget _stepButton(NDrawable icon, bool enabled, VoidCallback onTap) {
    final nc = NC.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkResponse(
        radius: 16,
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: NativeIcon(icon, tint: enabled ? nc.textPrimary : const Color(0xFFC3C8D0)),
          ),
        ),
      ),
    );
  }

  /// 52dp row: label 15sp text_primary, value, chevron 18dp text_secondary when tappable.
  Widget _row(NC nc, String label, Widget value, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Text(label, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
            const SizedBox(width: 16),
            Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: value)),
            if (onTap != null) NativeIcon(ND.icChevronRight, size: 18, tint: nc.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Lines / grid of a blank page style, drawn to fit any size.
class PaperPainter extends CustomPainter {
  PaperPainter(this.style);

  final BlankStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == BlankStyle.blank || size.isEmpty) return;
    final unit = size.width / 595;
    final ink = Paint()
      ..color = const Color(0xFFB0C4D8)
      ..strokeWidth = math.max(0.5, 0.8 * unit);
    final strong = Paint()
      ..color = const Color(0xFF8CA4BE)
      ..strokeWidth = math.max(0.6, 1.0 * unit);
    if (style == BlankStyle.grid || style == BlankStyle.graph) {
      final step = (style == BlankStyle.graph ? 18 : 36) * unit;
      var i = 0;
      for (var x = 0.0; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), style == BlankStyle.graph && i % 5 == 0 ? strong : ink);
        i++;
      }
      i = 0;
      for (var y = 0.0; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), style == BlankStyle.graph && i % 5 == 0 ? strong : ink);
        i++;
      }
      return;
    }
    final left = style == BlankStyle.cornell ? size.width * 0.28 : (style == BlankStyle.notebook ? 56 : 28) * unit;
    for (var y = 48 * unit; y < size.height - 36 * unit; y += 28 * unit) {
      canvas.drawLine(Offset(left, y), Offset(size.width - 24 * unit, y), ink);
    }
    if (style == BlankStyle.notebook || style == BlankStyle.cornell) {
      canvas.drawLine(
        Offset(left - 10 * unit, 20 * unit),
        Offset(left - 10 * unit, size.height - 20 * unit),
        Paint()
          ..color = const Color(0xFFE57373)
          ..strokeWidth = math.max(0.8, 1.2 * unit),
      );
    }
    if (style == BlankStyle.cornell) {
      canvas.drawLine(Offset(20 * unit, size.height * 0.82), Offset(size.width - 20 * unit, size.height * 0.82), strong);
    }
  }

  @override
  bool shouldRepaint(covariant PaperPainter oldDelegate) => oldDelegate.style != style;
}
