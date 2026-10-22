import 'package:flutter/material.dart';

import '../core/format.dart';
import '../data/doc_entry.dart';
import '../l10n/s.dart';
import '../native/native_colors.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';

/// Yellow of a bookmarked file's icon (Android color bookmark_yellow).
const Color bookmarkYellow = Color(0xFFFFC107);

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

/// One file in a list, exactly like the Android item_file row (68dp high): 36dp type icon, name
/// (15sp bold, middle ellipsis) + "New" tag, "when · size" (12sp), bookmark (yellow when on) and
/// ⋮ (40dp borderless buttons). In select mode the buttons turn into a checkbox.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onBookmark,
    required this.onMore,
    this.onLongPress,
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

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final s = S.of(context);
    final size = formatBytes(entry.bytes);
    final days = daysLeft;
    final meta = subtitle ??
        (days != null ? '${daysLeftText(context, days)} · $size' : '${formatWhen(context, openedAt ?? entry.modified)} · $size');
    // newly found file: "New" tag + light-grey row (new_file_bg) until it is opened
    final fresh = entry.isNew && days == null;
    final actions = showActions && !selecting;
    final on = entry.bookmarked;
    return Material(
      color: fresh ? c.newFileBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress ?? onMore,
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
            child: Row(
              children: [
                FileKindIcon(kind: entry.kind, size: 36),
                const SizedBox(width: 14),
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
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary),
                            ),
                          ),
                          if (fresh) ...[
                            const SizedBox(width: 6),
                            NewBadge(text: s.t('newTag')),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (actions && showBookmark)
                  RowIconButton(
                    drawable: on ? ND.icBookmark : ND.icBookmarkBorder,
                    tint: on ? c.bookmarkYellow : c.textHint,
                    tooltip: on ? s.t('removeBookmark') : s.t('bookmark'),
                    onTap: onBookmark,
                  ),
                if (actions) RowIconButton(drawable: ND.icMoreVert, tint: c.textSecondary, onTap: onMore),
                if (selecting)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: NativeCheckBox(checked: selected),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The blue "New" tag after a fresh file's name (bg_new_badge: primary, 8dp corners, 10sp bold).
class NewBadge extends StatelessWidget {
  const NewBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: NC.of(context).primary, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700, height: 1.3)),
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
    final color = checked ? c.primary : const Color(0xFFB8BEC8);
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
            borderRadius: BorderRadius.circular(2),
          ),
          child: checked ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
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
