import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';

/// Current page of a [PagedView] and jumps to a page (Go to page, search results, slider).
class PagedController extends ChangeNotifier {
  int _page = 0;
  _PagedViewState? _view;
  (int, double, bool)? _pending;

  /// 0-based page at the top of the screen (vertical) or on screen (page by page).
  int get page => _page;

  /// Shows [page]; [fraction] is a position inside the page (0 = top, 1 = bottom), and with
  /// [third] that spot is placed a third of the way down the screen (search results).
  void jumpTo(int page, {double fraction = 0, bool third = false}) {
    final view = _view;
    if (view == null) {
      _pending = (page, fraction, third);
      _page = page;
      return;
    }
    view._jump(page, fraction, third);
  }

  void _set(int page) {
    if (page == _page) return;
    _page = page;
    notifyListeners();
  }
}

/// Pages of any document type (PDF, Word, TXT, PPT) in a vertical list ("Continuous pages")
/// or page by page, with pinch / double-tap zoom and the page slider on the right edge
/// (like the Android PageScrollBar: appears while scrolling, fades after 2 s, drag or tap the
/// strip to jump by page; its lowest position stays [bottomGap] above the bottom).
class PagedView extends StatefulWidget {
  const PagedView({
    super.key,
    required this.controller,
    required this.count,
    required this.aspectOf,
    required this.itemBuilder,
    this.horizontal = false,
    this.onTap,
    this.bottomGap = 6,
    this.layoutVersion = 0,
  });

  final PagedController controller;
  final int count;

  /// Height / width of a page.
  final double Function(int index) aspectOf;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final bool horizontal;
  final VoidCallback? onTap;
  final double bottomGap;

  /// Change it when page sizes change (the list re-measures).
  final int layoutVersion;

  @override
  State<PagedView> createState() => _PagedViewState();
}

class _PagedViewState extends State<PagedView> {
  static const _side = 8.0;
  static const _gap = 8.0;
  // item_page.xml: 8dp sides, 4dp above / below each page; the list has 6dp more at both ends
  static const _padTop = 10.0;
  static const _thumbWidth = 30.0;
  static const _thumbHeight = 46.0;

  final _scroll = ScrollController();
  final _zoom = TransformationController();
  PageController? _pager;
  bool _zoomed = false;
  Offset _tapAt = Offset.zero;

  List<double> _offsets = const [_padTop];
  double _offsetsWidth = -1;
  int _offsetsCount = -1;
  int _offsetsVersion = -1;
  double _lastWidth = -1;

  bool _sliderOn = false;
  bool _shownOnce = false;
  Timer? _hideTimer;
  bool _dragging = false;
  double _dragFraction = 0;
  double _grab = 0;

  @override
  void initState() {
    super.initState();
    widget.controller._view = this;
    _scroll.addListener(_onScroll);
    _zoom.addListener(_onZoom);
    if (widget.horizontal) _pager = PageController(initialPage: widget.controller.page);
    if (!widget.horizontal && widget.controller.page > 0 && widget.controller._pending == null) {
      widget.controller._pending = (widget.controller.page, 0.0, false);
    }
  }

  @override
  void didUpdateWidget(PagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller._view == this) oldWidget.controller._view = null;
      widget.controller._view = this;
    }
    if (oldWidget.horizontal != widget.horizontal) {
      _zoom.value = Matrix4.identity();
      _zoomed = false;
      final page = widget.controller.page;
      if (widget.horizontal) {
        _pager = PageController(initialPage: page);
      } else {
        final old = _pager;
        _pager = null;
        if (old != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
        }
        widget.controller._pending = (page, 0.0, false);
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (widget.controller._view == this) widget.controller._view = null;
    _scroll.dispose();
    _zoom.dispose();
    _pager?.dispose();
    super.dispose();
  }

  void _onZoom() {
    final zoomed = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  void _toggleZoom() {
    if (_zoom.value.getMaxScaleOnAxis() > 1.2) {
      _zoom.value = Matrix4.identity();
      return;
    }
    const scale = 2.0;
    _zoom.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(-_tapAt.dx * (scale - 1), -_tapAt.dy * (scale - 1), 0);
  }

  // ------------------------------------------------------------------ page positions

  void _ensureOffsets(double width) {
    if (width == _offsetsWidth && widget.count == _offsetsCount && widget.layoutVersion == _offsetsVersion) return;
    final pageWidth = math.max(40.0, width - 2 * _side);
    final list = List<double>.filled(widget.count + 1, 0);
    var y = _padTop;
    for (var i = 0; i < widget.count; i++) {
      list[i] = y;
      y += pageWidth * widget.aspectOf(i) + _gap;
    }
    list[widget.count] = y;
    _offsets = list;
    _offsetsWidth = width;
    _offsetsCount = widget.count;
    _offsetsVersion = widget.layoutVersion;
  }

  double _extent(int index) => _offsets[index + 1] - _offsets[index];

  int _pageAt(double y) {
    if (widget.count <= 0 || _offsets.length < 2) return 0;
    var low = 0;
    var high = math.min(widget.count, _offsets.length - 1) - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_offsets[mid] <= y) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  bool get _scrollable =>
      !widget.horizontal && widget.count > 1 && _scroll.hasClients && _scroll.position.maxScrollExtent > 0;

  double _scrollFraction() {
    if (!_scroll.hasClients) return 0;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (_scroll.position.pixels / max).clamp(0.0, 1.0);
  }

  void _onScroll() {
    if (!_scroll.hasClients || widget.count == 0 || widget.horizontal) return;
    final position = _scroll.position;
    var page = _pageAt(position.pixels + 1);
    if (page < widget.count - 1 && page + 1 < _offsets.length && _offsets[page + 1] - position.pixels < position.viewportDimension / 3) {
      page++;
    }
    widget.controller._set(page);
    if (!_dragging && _scrollable) _reveal();
  }

  void _jump(int page, double fraction, bool third) {
    if (widget.count == 0) {
      widget.controller._pending = (page, fraction, third);
      return;
    }
    final target = page.clamp(0, widget.count - 1);
    if (widget.horizontal) {
      final pager = _pager;
      if (pager != null && pager.hasClients) {
        pager.jumpToPage(target);
      } else {
        widget.controller._page = target;
      }
      return;
    }
    if (!_scroll.hasClients || _offsets.length <= target + 1) {
      widget.controller._pending = (target, fraction, third);
      widget.controller._page = target;
      return;
    }
    final viewport = _scroll.position.viewportDimension;
    var y = _offsets[target] + (_extent(target) - _gap) * fraction.clamp(0.0, 1.0);
    if (third) y -= viewport / 3;
    _scroll.jumpTo(y.clamp(0.0, _scroll.position.maxScrollExtent));
    widget.controller._set(target);
  }

  void _consumePending() {
    if (!mounted) return;
    final pending = widget.controller._pending;
    if (pending == null) return;
    if (!widget.horizontal && !_scroll.hasClients) return;
    widget.controller._pending = null;
    _jump(pending.$1, pending.$2, pending.$3);
  }

  /// Keeps the same spot on screen when the width changes (rotation).
  void _keepPageAfterResize() {
    if (!_scroll.hasClients || widget.count == 0 || _offsets.length < 2) return;
    final pixels = _scroll.position.pixels;
    final page = _pageAt(pixels);
    final extent = page + 1 < _offsets.length ? _extent(page) : 1.0;
    final fraction = extent <= 0 ? 0.0 : ((pixels - _offsets[page]) / extent).clamp(0.0, 1.0);
    widget.controller._pending = (page, fraction, false);
  }

  // ------------------------------------------------------------------ page slider

  void _reveal() {
    _hideTimer?.cancel();
    if (!_sliderOn) setState(() => _sliderOn = true);
    if (!_dragging) {
      _hideTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && !_dragging) setState(() => _sliderOn = false);
      });
    }
  }

  void _jumpFraction(double fraction) {
    if (!_scroll.hasClients || widget.count == 0) return;
    final max = _scroll.position.maxScrollExtent;
    if (fraction >= 0.999) {
      _scroll.jumpTo(max);
      return;
    }
    final position = fraction * widget.count;
    final page = position.floor().clamp(0, widget.count - 1);
    final y = _offsets[page] + (position - page) * _extent(page);
    _scroll.jumpTo(y.clamp(0.0, max));
  }

  void _dragStart(double y, double travel) {
    if (!_scrollable) return;
    final thumbTop = (_dragging ? _dragFraction : _scrollFraction()) * travel;
    final onThumb = y >= thumbTop - 12 && y <= thumbTop + _thumbHeight + 12;
    _grab = onThumb ? (y - thumbTop).clamp(0.0, _thumbHeight) : _thumbHeight / 2;
    _dragging = true;
    _hideTimer?.cancel();
    _dragTo(y, travel);
  }

  void _dragTo(double y, double travel) {
    if (!_dragging) return;
    final fraction = travel <= 0 ? 0.0 : ((y - _grab) / travel).clamp(0.0, 1.0);
    _jumpFraction(fraction);
    setState(() => _dragFraction = fraction);
  }

  void _dragEnd() {
    if (!_dragging) return;
    _dragging = false;
    _reveal();
    setState(() {});
  }

  /// ic_page_slider_thumb: dark rounded tab with ≡ and a soft shadow ring (30 × 46dp).
  Widget _thumb() => const NativeIcon(ND.icPageSliderThumb, width: _thumbWidth, height: _thumbHeight);

  Widget _slider() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final travel = math.max(0.0, constraints.maxHeight - _thumbHeight);
        return IgnorePointer(
          ignoring: !_sliderOn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _dragStart(details.localPosition.dy, travel),
            onTapUp: (_) => _dragEnd(),
            onVerticalDragStart: (details) => _dragStart(details.localPosition.dy, travel),
            onVerticalDragUpdate: (details) => _dragTo(details.localPosition.dy, travel),
            onVerticalDragEnd: (_) => _dragEnd(),
            onVerticalDragCancel: _dragEnd,
            child: AnimatedBuilder(
              animation: _scroll,
              builder: (context, _) {
                final fraction = _dragging ? _dragFraction : _scrollFraction();
                return Stack(
                  children: [
                    PositionedDirectional(
                      end: 2,
                      top: fraction * travel,
                      child: AnimatedOpacity(
                        opacity: _sliderOn ? 1 : 0,
                        duration: const Duration(milliseconds: 250),
                        child: _thumb(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ build

  Widget _paper(BuildContext context, int index) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        // white page with 1dp elevation
        color: Colors.white,
        boxShadow: [BoxShadow(color: Color(0x24000000), blurRadius: 2, offset: Offset(0, 1))],
      ),
      child: widget.itemBuilder(context, index),
    );
  }

  Widget _list() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: _padTop, bottom: 2),
      itemCount: widget.count,
      itemExtentBuilder: (index, dimensions) {
        if (index >= widget.count || index + 1 >= _offsets.length) return null;
        return _extent(index);
      },
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.fromLTRB(_side, 0, _side, _gap),
        child: _paper(context, index),
      ),
    );
  }

  Widget _pages() {
    return PageView.builder(
      controller: _pager,
      itemCount: widget.count,
      physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
      onPageChanged: widget.controller._set,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.all(8),
        child: Center(
          child: AspectRatio(
            aspectRatio: 1 / widget.aspectOf(index),
            child: _paper(context, index),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (!widget.horizontal) {
          if (_lastWidth >= 0 && (width - _lastWidth).abs() > 0.5) _keepPageAfterResize();
          _lastWidth = width;
          _ensureOffsets(width);
          if (widget.controller._pending != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _consumePending());
          }
          if (!_shownOnce) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _shownOnce || !_scrollable) return;
              _shownOnce = true;
              _reveal();
            });
          }
        }
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onTap,
                onDoubleTapDown: (details) => _tapAt = details.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: 5,
                  child: widget.horizontal ? _pages() : _list(),
                ),
              ),
            ),
            if (!widget.horizontal)
              PositionedDirectional(
                top: 0,
                bottom: widget.bottomGap,
                end: 0,
                width: 44,
                child: _slider(),
              ),
          ],
        );
      },
    );
  }
}
