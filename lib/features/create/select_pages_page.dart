import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import 'pdf_thumbs.dart';
import 'tool_widgets.dart';

/// "Select pages": the PDF's pages in a 2-column grid with a checkbox each, Select all and
/// "Continue (n)". Returns the chosen 0-based page numbers in order.
/// Native activity_select_pages.xml + item_page_thumb.xml.
class SelectPagesPage extends StatefulWidget {
  const SelectPagesPage({super.key, required this.thumbs, required this.count, this.initial = const {}});

  final PdfThumbs thumbs;
  final int count;
  final Set<int> initial;

  @override
  State<SelectPagesPage> createState() => _SelectPagesPageState();
}

class _SelectPagesPageState extends State<SelectPagesPage> {
  late final Set<int> _selected = {...widget.initial};

  void _toggleAll() {
    setState(() {
      if (_selected.length == widget.count) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(List<int>.generate(widget.count, (i) => i));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final nc = NC.of(context);
    final n = _selected.length;
    return Scaffold(
      backgroundColor: nc.surface,
      appBar: NativeTopBar(
        titleWidget: Text(
          n == 0 ? s.t('selectPages') : s.t('selected', {'count': '$n'}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: nc.textPrimary),
        ),
        actions: [
          NativeIconButton(ND.icSelectAll, tint: nc.textPrimary, tooltip: s.t('selectAll'), onPressed: _toggleAll),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cell = (constraints.maxWidth - 12) / 2;
                return GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisExtent: (cell - 16) * 4 / 3 + 16),
                  itemCount: widget.count,
                  itemBuilder: (context, index) => _thumb(index),
                );
              },
            ),
          ),
          NativeBottomAction(
            label: n == 0 ? s.t('continueAction') : s.t('continueN', {'count': '$n'}),
            enabled: n > 0,
            onPressed: () => Navigator.of(context).pop(_selected.toList()..sort()),
          ),
        ],
      ),
    );
  }

  /// item_page_thumb.xml: 6dp padding, bg_thumb (selected: #E9EBEF + 2dp primary, else #F3F5F9 +
  /// 1dp #E3E6EC, 6dp), 3:4 page, #33000000 overlay when selected, checkbox top-end, number pill.
  Widget _thumb(int index) {
    final on = _selected.contains(index);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => on ? _selected.remove(index) : _selected.add(index)),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE9EBEF) : const Color(0xFFF3F5F9),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? NC.of(context).primary : const Color(0xFFE3E6EC), width: on ? 2 : 1),
          ),
          child: Stack(
            children: [
              Positioned.fill(child: PdfThumbImage(thumbs: widget.thumbs, index: index)),
              if (on) const Positioned.fill(child: ColoredBox(color: Color(0x33000000))),
              PositionedDirectional(top: 0, end: 0, child: NativeCheckBox(checked: on)),
              PositionedDirectional(
                start: 4,
                bottom: 4,
                child: Container(
                  height: 20,
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0x99414754), borderRadius: BorderRadius.circular(3)),
                  child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
