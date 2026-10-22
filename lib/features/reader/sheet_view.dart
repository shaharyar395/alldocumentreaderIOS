import 'package:flutter/material.dart';

import 'doc_pages.dart' show currentHitColor, hitColor;
import 'sheet_parser.dart';

/// One Excel sheet as a grid like a spreadsheet app: column letters across the top (they stay
/// while scrolling down), row numbers down the side, the sheet's own column widths. Pinch or
/// double-tap to zoom; one tap toggles the reader bars.
class SheetGrid extends StatefulWidget {
  const SheetGrid({
    super.key,
    required this.sheet,
    required this.emptyLabel,
    this.marks = const {},
    this.current,
    this.onTap,
  });

  final SheetData sheet;
  final String emptyLabel;

  /// Cells with search results ([SheetData.key]); [current] is the selected one.
  final Set<int> marks;
  final int? current;
  final VoidCallback? onTap;

  @override
  State<SheetGrid> createState() => SheetGridState();
}

class SheetGridState extends State<SheetGrid> {
  static const _rowHeight = 24.0;
  static const _headerWidth = 44.0;
  static const _line = Color(0xFFDADDE2);

  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  double _scale = 1;
  double _baseScale = 1;

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// Scrolls so that the cell is in view (search results).
  void revealCell(int row, int col) {
    final rowHeight = _rowHeight * _scale;
    if (_vertical.hasClients) {
      final viewport = _vertical.position.viewportDimension;
      _vertical.jumpTo((row * rowHeight - viewport / 3).clamp(0.0, _vertical.position.maxScrollExtent));
    }
    if (_horizontal.hasClients) {
      var x = _headerWidth * _scale;
      for (var c = 0; c < col; c++) {
        x += widget.sheet.widthOf(c) * _scale;
      }
      final viewport = _horizontal.position.viewportDimension;
      _horizontal.jumpTo((x - viewport / 4).clamp(0.0, _horizontal.position.maxScrollExtent));
    }
  }

  bool _numeric(String text) {
    final cleaned = text.replaceAll(',', '').replaceAll('%', '').trim();
    return cleaned.isNotEmpty && double.tryParse(cleaned) != null;
  }

  Widget _cell(
    String text,
    double width,
    double height,
    double fontSize, {
    bool header = false,
    bool hit = false,
    bool current = false,
  }) {
    if (width < 1) return SizedBox(width: 0, height: height);
    final Color? background;
    if (current) {
      background = currentHitColor;
    } else if (hit) {
      background = hitColor;
    } else if (header) {
      background = const Color(0xFFF1F3F6);
    } else {
      background = null;
    }
    final AlignmentGeometry alignment;
    if (header) {
      alignment = Alignment.center;
    } else if (_numeric(text)) {
      alignment = AlignmentDirectional.centerEnd;
    } else {
      alignment = AlignmentDirectional.centerStart;
    }
    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.symmetric(horizontal: width > 10 ? 4 * _scale : 0),
      alignment: alignment,
      decoration: BoxDecoration(
        color: background,
        border: const Border(
          right: BorderSide(color: _line, width: 0.6),
          bottom: BorderSide(color: _line, width: 0.6),
        ),
      ),
      child: Text(
        text.replaceAll('\n', ' '),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.2,
          color: header ? const Color(0xFF5F6670) : const Color(0xFF1B2333),
          fontWeight: header ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    if (sheet.maxRow < 0) {
      return GestureDetector(
        onTap: widget.onTap,
        child: ColoredBox(
          color: Colors.white,
          child: Center(child: Text(widget.emptyLabel, style: const TextStyle(color: Color(0xFF8B95A8)))),
        ),
      );
    }
    final columns = sheet.maxCol + 1;
    final rows = sheet.maxRow + 1;
    final rowHeight = _rowHeight * _scale;
    final headerWidth = _headerWidth * _scale;
    final fontSize = 12 * _scale;
    final widths = [for (var c = 0; c < columns; c++) sheet.widthOf(c) * _scale];
    final total = headerWidth + widths.fold<double>(0, (sum, w) => sum + w);
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: () => setState(() => _scale = _scale > 1.2 ? 1 : 1.8),
      onScaleStart: (_) => _baseScale = _scale,
      onScaleUpdate: (details) {
        if (details.pointerCount < 2) return;
        setState(() => _scale = (_baseScale * details.scale).clamp(0.5, 3.0));
      },
      child: ColoredBox(
        color: Colors.white,
        child: SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: total,
            child: Column(
              children: [
                Row(
                  children: [
                    _cell('', headerWidth, rowHeight, fontSize, header: true),
                    for (var c = 0; c < columns; c++) _cell(columnName(c), widths[c], rowHeight, fontSize, header: true),
                  ],
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _vertical,
                    itemCount: rows,
                    itemExtent: rowHeight,
                    itemBuilder: (context, r) {
                      return Row(
                        children: [
                          _cell('${r + 1}', headerWidth, rowHeight, fontSize, header: true),
                          for (var c = 0; c < columns; c++)
                            _cell(
                              sheet.cell(r, c),
                              widths[c],
                              rowHeight,
                              fontSize,
                              hit: widget.marks.contains(SheetData.key(r, c)),
                              current: widget.current == SheetData.key(r, c),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
