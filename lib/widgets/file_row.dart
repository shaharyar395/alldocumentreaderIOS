import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/doc_entry.dart';
import '../l10n/s.dart';
import '../native/native_colors.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';

/// Kept name: colour of a bookmarked file's icon (Android color bookmark_yellow).
const Color bookmarkYellow = Color(0xFFF59E0B);

/// "Just now", "12 minutes ago", "3 hours ago", otherwise a short date — like the Android app's
/// util/Ext.kt formatWhen (DateUtils relative time under a day, DateFormat.SHORT after that).
String formatWhen(BuildContext context, DateTime time) {
  final s = S.of(context);
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return s.t('whenJustNow');
  if (diff.inHours < 1) {
    final n = diff.inMinutes;
    return n == 1 ? s.t('whenMinuteAgo') : s.t('whenMinutesAgo', {'n': '$n'});
  }
  if (diff.inDays < 1) {
    final n = diff.inHours;
    return n == 1 ? s.t('whenHourAgo') : s.t('whenHoursAgo', {'n': '$n'});
  }
  return MaterialLocalizations.of(context).formatCompactDate(time);
}

/// "N days left" / "1 day left" of a file in the recycle bin.
String daysLeftText(BuildContext context, int days) {
  final s = S.of(context);
  return days == 1 ? s.t('daysLeftOne', {'days': '$days'}) : s.t('daysLeft', {'days': '$days'});
}

/// One file in a list, like the Android item_file row ("Plum deck" 1.0.35+): a 72 dp rounded
/// card (surface, 14 dp corners) 16 dp in from the sides with 4 dp between rows, the 42 dp
/// outlined type circle, name (15 sp medium, middle ellipsis) + "New" tag, "when · size" (12 sp),
/// bookmark (accent when on) and ⋮. A new file's card is tinted with a soft outline; a ticked one
/// in select mode is accent_container with a primary outline. With [onDelete], dragging the card
/// toward the start reveals the swipe layer (Bookmark + Delete), like FileSwipeHelper.
class FileRow extends StatefulWidget {
  const FileRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onBookmark,
    required this.onMore,
    this.onLongPress,
    this.onDelete,
    this.selecting = false,
    this.selected = false,
    this.daysLeft,
    this.showActions = true,
    this.showBookmark = true,
    this.openedAt,
    this.subtitle,
  });

  final DocEntry entry;
  final VoidCallback onTap;
  final VoidCallback onBookmark;
  final VoidCallback onMore;
  final bool selecting;
  final bool selected;

  /// Swipe-left Delete (asks first, like the ⋮ menu). Null = no swipe on this row.
  final VoidCallback? onDelete;

  /// Recycle bin: "N days left · size" instead of the date.
  final int? daysLeft;

  /// Long press (select mode in lists); the ⋮ menu when not given.
  final VoidCallback? onLongPress;

  /// Bookmark and ⋮ buttons (hidden in Directories lists, like the Android app).
  final bool showActions;

  /// Only the bookmark button (the recycle bin keeps ⋮ but has no bookmark).
  final bool showBookmark;

  /// Recent / Bookmarks: when the file was opened, shown instead of its modified date.
  final DateTime? openedAt;

  /// Replaces the "when · size" line (e.g. the storage browser's "MM/dd/yyyy · size").
  final String? subtitle;

  /// The one row whose swipe layer is open (opening another one, or scrolling, closes it).
  static final ValueNotifier<Object?> openRow = ValueNotifier<Object?>(null);

  @override
  State<FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<FileRow> with SingleTickerProviderStateMixin {
  /// Width of the revealed actions: two 52 dp buttons + 8 dp padding + 8 dp gap (REVEAL_DP).
  static const double _reveal = 120;

  late final AnimationController _offset = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: 1,
    duration: const Duration(milliseconds: 200),
  );
  final Object _token = Object();

  bool get _canSwipe => widget.onDelete != null && widget.showActions && !widget.selecting;

  @override
  void initState() {
    super.initState();
    FileRow.openRow.addListener(_onOtherOpened);
  }

  @override
  void didUpdateWidget(covariant FileRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_canSwipe && _offset.value != 0) _offset.value = 0;
  }

  @override
  void dispose() {
    FileRow.openRow.removeListener(_onOtherOpened);
    if (FileRow.openRow.value == _token) FileRow.openRow.value = null;
    _offset.dispose();
    super.dispose();
  }

  void _onOtherOpened() {
    if (FileRow.openRow.value != _token && _offset.value != 0) _settle(false);
  }

  void _settle(bool open) {
    _offset.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
    if (open) {
      FileRow.openRow.value = _token;
    } else if (FileRow.openRow.value == _token) {
      FileRow.openRow.value = null;
    }
  }

  /// Toward the start = left in LTR, right in RTL.
  double _sign(BuildContext context) => Directionality.of(context) == TextDirection.rtl ? 1 : -1;

  void _onDragUpdate(DragUpdateDetails d) {
    final toStart = d.primaryDelta! * _sign(context);
    _offset.value = (_offset.value + toStart / _reveal).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity! * _sign(context);
    if (v.abs() > 300) {
      _settle(v > 0);
    } else {
      _settle(_offset.value > 0.5);
    }
  }

  void _close() => _settle(false);

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final s = S.of(context);
    final entry = widget.entry;
    final size = formatBytes(entry.bytes);
    final days = widget.daysLeft;
    final meta = widget.subtitle ??
        (days != null ? '${daysLeftText(context, days)} · $size' : '${formatWhen(context, widget.openedAt ?? entry.modified)} · $size');
    // newly found file: "New" tag + tinted card until it is opened
    final fresh = entry.isNew && days == null;
    final actions = widget.showActions && !widget.selecting;
    final on = entry.bookmarked;
    final isSelected = widget.selecting && widget.selected;
    final radius = BorderRadius.circular(14);
    final card = Material(
      color: isSelected ? c.accentContainer : (fresh ? c.newFileBg : c.surface),
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: isSelected
            ? BorderSide(color: c.primary, width: 1.5)
            : fresh
                ? BorderSide(color: c.accentSoft, width: 1)
                : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (_offset.value != 0) {
            _close();
            return;
          }
          widget.onTap();
        },
        onLongPress: widget.onLongPress ?? widget.onMore,
        splashColor: c.rowPressed,
        highlightColor: c.rowPressed.withValues(alpha: 0.5),
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
            child: Row(
              children: [
                FileKindIcon(kind: entry.kind, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: MiddleEllipsisText(
                              entry.name,
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.textPrimary, height: 1.2),
                            ),
                          ),
                          if (fresh) ...[
                            const SizedBox(width: 6),
                            NewBadge(text: s.t('newTag')),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textSecondary, height: 1.2),
                      ),
                    ],
                  ),
                ),
                if (actions && widget.showBookmark)
                  RowIconButton(
                    drawable: on ? ND.icBookmark : ND.icBookmarkBorder,
                    tint: on ? c.accent : c.textHint,
                    tooltip: on ? s.t('removeBookmark') : s.t('bookmark'),
                    onTap: widget.onBookmark,
                    size: 44,
                    padding: 12,
                  ),
                if (actions) RowIconButton(drawable: ND.icMoreVert, tint: c.textSecondary, onTap: widget.onMore, size: 44, padding: 12),
                if (widget.selecting)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: NativeCheckBox(checked: widget.selected),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    Widget row = card;
    if (_canSwipe) {
      final sign = _sign(context);
      row = Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _offset,
              builder: (context, child) => Visibility(
                visible: _offset.value > 0,
                maintainState: true,
                child: child!,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.swipeBg, borderRadius: radius),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _SwipeButton(
                        drawable: on ? ND.icBookmark : ND.icBookmarkBorder,
                        label: on ? s.t('removeBookmark') : s.t('bookmark'),
                        onTap: () {
                          _close();
                          widget.onBookmark();
                        },
                      ),
                      _SwipeButton(
                        drawable: ND.dsFilesIcDelete,
                        label: s.t('delete'),
                        onTap: () {
                          _close();
                          widget.onDelete?.call();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _offset,
            builder: (context, child) => Transform.translate(offset: Offset(sign * _reveal * _offset.value, 0), child: child),
            child: GestureDetector(
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              child: card,
            ),
          ),
        ],
      );
    }
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 4), child: row);
  }
}

/// A 52 dp round action on the swipe layer (ds_files_bg_swipe_btn: faint white fill, 1.5 dp
/// swipe_icon outline, 6 dp inset), its icon tinted swipe_icon.
class _SwipeButton extends StatelessWidget {
  const _SwipeButton({required this.drawable, required this.label, required this.onTap});

  final NDrawable drawable;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Semantics(
      button: true,
      label: label,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Material(
            color: const Color(0x1FFFFFFF),
            shape: CircleBorder(side: BorderSide(color: c.swipeIcon, width: 1.5)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              splashColor: const Color(0x33FFFFFF),
              child: Padding(padding: const EdgeInsets.all(9), child: NativeIcon(drawable, tint: c.swipeIcon)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "New" tag after a fresh file's name (bg_new_badge: accent_soft, 8 dp corners, 10 sp medium).
class NewBadge extends StatelessWidget {
  const NewBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: c.textPrimary, fontSize: 10, fontWeight: FontWeight.w500, height: 1.3)),
    );
  }
}

/// A 40dp ImageButton with 10dp padding and a borderless ripple (selectableItemBackgroundBorderless).
class RowIconButton extends StatelessWidget {
  const RowIconButton({super.key, required this.drawable, required this.onTap, this.tint, this.tooltip, this.size = 40, this.padding = 10});

  final NDrawable drawable;
  final VoidCallback? onTap;
  final Color? tint;
  final String? tooltip;
  final double size;
  final double padding;

  @override
  Widget build(BuildContext context) {
    Widget button = SizedBox(
      width: size,
      height: size,
      child: InkResponse(
        onTap: onTap,
        radius: size / 2 + 4,
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: NativeIcon(drawable, size: size - padding * 2, tint: tint),
        ),
      ),
    );
    final tip = tooltip;
    if (tip != null) button = Tooltip(message: tip, child: button);
    return Material(type: MaterialType.transparency, child: button);
  }
}

/// MaterialCheckBox with app:buttonTint="@color/checkbox_tint": primary when checked, #B8BEC8 off.
class NativeCheckBox extends StatelessWidget {
  const NativeCheckBox({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final color = checked ? c.primary : c.radioOff;
    return SizedBox(
      width: 32,
      height: 32,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: checked ? color : Colors.transparent,
            border: Border.all(color: color, width: 2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: checked ? Icon(Icons.check, size: 14, color: c.onPrimary) : null,
        ),
      ),
    );
  }
}

/// One line of text shortened in the middle ("Annual rep…2024.pdf"), like android:ellipsize="middle".
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, required this.style, this.textAlign});

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth;
        var shown = text;
        if (max.isFinite && text.length > 3 && _width(text, effective, direction, scaler) > max) {
          final chars = text.characters.toList();
          var lo = 0, hi = chars.length - 1;
          var best = '…';
          while (lo <= hi) {
            final keep = (lo + hi) ~/ 2;
            final head = (keep + 1) ~/ 2;
            final tail = keep - head;
            final candidate = '${chars.take(head).join()}…${chars.skip(chars.length - tail).join()}';
            if (_width(candidate, effective, direction, scaler) <= max) {
              best = candidate;
              lo = keep + 1;
            } else {
              hi = keep - 1;
            }
          }
          shown = best;
        }
        return Text(shown, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, textAlign: textAlign, style: style);
      },
    );
  }

  static double _width(String text, TextStyle style, TextDirection direction, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }
}

/// The type icon used by file rows, the ⋮ menu header and the info sheet: the native FileType
/// drawable (ic_cat_pdf, ic_cat_word, … ic_file_unknown) at [size] dp.
class FileKindIcon extends StatelessWidget {
  const FileKindIcon({super.key, required this.kind, this.size = 36});

  final DocKind kind;
  final double size;

  static Color colorOf(BuildContext context, DocKind kind) {
    final c = NC.of(context);
    return switch (kind) {
      DocKind.pdf => c.typePdf,
      DocKind.word => c.typeWord,
      DocKind.excel => c.typeExcel,
      DocKind.ppt => c.typePpt,
      DocKind.txt => c.typeTxt,
      DocKind.image => c.typeImage,
      DocKind.other => c.textSecondary,
    };
  }

  static IconData iconOf(DocKind kind) {
    return switch (kind) {
      DocKind.pdf => Icons.picture_as_pdf_rounded,
      DocKind.word => Icons.description_rounded,
      DocKind.excel => Icons.table_chart_rounded,
      DocKind.ppt => Icons.slideshow_rounded,
      DocKind.txt => Icons.notes_rounded,
      DocKind.image => Icons.image_rounded,
      DocKind.other => Icons.insert_drive_file_rounded,
    };
  }

  /// The native FileType.icon drawable of [kind].
  static NDrawable drawableOf(DocKind kind) {
    return switch (kind) {
      DocKind.pdf => ND.icCatPdf,
      DocKind.word => ND.icCatWord,
      DocKind.excel => ND.icCatExcel,
      DocKind.ppt => ND.icCatPpt,
      DocKind.txt => ND.icCatTxt,
      DocKind.image => ND.icCatImage,
      DocKind.other => ND.icFileUnknown,
    };
  }

  @override
  Widget build(BuildContext context) => NativeIcon(drawableOf(kind), size: size);
}
