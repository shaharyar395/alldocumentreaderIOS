import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';

/// Centered white pill with a spinner: "Processing… (6%)", "Converting… (99%)". Blocks touches
/// while it is shown. It lives in the root overlay, so it never pops a route by mistake.
/// Native dialog_progress_pill.xml: 56dp high, min 210dp wide, bg_white_round (surface, 14dp),
/// 20dp primary spinner, 12dp gap, 15sp bold text_primary; window dim 0.45.
class ProgressPill {
  ProgressPill(this.context);

  final BuildContext context;
  OverlayEntry? _entry;
  final ValueNotifier<String> _text = ValueNotifier<String>('');

  bool get showing => _entry != null;

  void show(String text) {
    _text.value = text;
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (context) {
        final nc = NC.of(context);
        return Stack(
          children: [
            const ModalBarrier(dismissible: false, color: Color(0x73000000)),
            Center(
              child: Material(
                color: nc.surface,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  height: 56,
                  constraints: const BoxConstraints(minWidth: 210),
                  padding: const EdgeInsetsDirectional.only(start: 18, end: 22),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: nc.primary),
                      ),
                      const SizedBox(width: 12),
                      ValueListenableBuilder<String>(
                        valueListenable: _text,
                        builder: (context, value, _) => Text(
                          value,
                          style: TextStyle(color: nc.textPrimary, fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _entry = entry;
    overlay.insert(entry);
  }

  void dismiss() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

/// MaterialButton with style PillButton (primary, white 16sp bold, 24dp corners) or, with [gray],
/// GrayPillButton (btn_gray, text_primary). Disabled: bg_apply_btn's #B7CFF3.
class NativePillButton extends StatelessWidget {
  const NativePillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.gray = false,
    this.height = 48,
    this.width,
    this.fontSize = 16,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool gray;
  final double height;
  final double? width;
  final double fontSize;

  /// Replaces the primary colour (e.g. a red Delete).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final enabled = onPressed != null;
    final bg = gray ? nc.btnGray : (enabled ? (color ?? nc.primary) : const Color(0xFFB7CFF3));
    return SizedBox(
      height: height,
      width: width,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          splashColor: gray ? const Color(0x1F000000) : const Color(0x33FFFFFF),
          highlightColor: gray ? const Color(0x1F000000) : const Color(0x1FFFFFFF),
          onTap: onPressed,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: gray ? nc.textPrimary : Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ImageButton with ?attr/selectableItemBackgroundBorderless: [size] box, [padding] around the
/// drawable, optional app:tint (pass the disabled tint yourself, like @color/tool_tint).
class NativeIconButton extends StatelessWidget {
  const NativeIconButton(
    this.icon, {
    super.key,
    required this.onPressed,
    this.size = 44,
    this.padding = 10,
    this.tint,
    this.tooltip,
  });

  final NDrawable icon;
  final VoidCallback? onPressed;
  final double size;
  final double padding;
  final Color? tint;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: onPressed,
        radius: size / 2,
        child: SizedBox(
          width: size,
          height: size,
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: NativeIcon(icon, size: size - padding * 2, tint: tint),
          ),
        ),
      ),
    );
    final message = tooltip;
    return message == null ? button : Tooltip(message: message, child: button);
  }
}

/// Native white top bar (56dp, surface): 44dp ic_back at 4dp start, title 18sp bold text_primary,
/// optional actions at the end.
class NativeTopBar extends StatelessWidget implements PreferredSizeWidget {
  const NativeTopBar({super.key, this.title, this.titleWidget, this.onBack, this.actions = const [], this.color});

  final String? title;
  final Widget? titleWidget;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Color? color;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return AppBar(
      toolbarHeight: 56,
      backgroundColor: color ?? nc.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      title: Row(
        children: [
          const SizedBox(width: 4),
          NativeIconButton(ND.icBack, tint: nc.textPrimary, onPressed: onBack ?? () => Navigator.maybePop(context)),
          const SizedBox(width: 4),
          Expanded(
            child: titleWidget ??
                Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary),
                ),
          ),
          ...actions,
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// item_result_tool.xml: borderless ripple, 10dp top / bottom, 52dp bg_tool_tile (surface_variant,
/// 14dp) with a 30dp icon, 8dp gap, label 13sp text_primary (max 2 lines).
class NativeToolCell extends StatelessWidget {
  const NativeToolCell({super.key, required this.icon, required this.label, required this.onTap});

  final NDrawable icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: onTap,
        radius: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: nc.surfaceVariant, borderRadius: BorderRadius.circular(14)),
                child: NativeIcon(icon, size: 30),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: nc.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// GridLayout with 4 equal columns of [NativeToolCell]s (short last row keeps the column width).
class NativeToolGrid extends StatelessWidget {
  const NativeToolGrid({super.key, required this.cells});

  final List<Widget> cells;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < cells.length; start += 4) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = start; i < start + 4; i++) Expanded(child: i >= cells.length ? const SizedBox.shrink() : cells[i]),
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

/// Android RadioButton look (20dp ring, 2dp stroke, 10dp dot) in a 48dp box; app:buttonTint [color].
class NativeRadio extends StatelessWidget {
  const NativeRadio({super.key, required this.checked, this.color, this.offColor});

  final bool checked;
  final Color? color;

  /// Ring colour when not checked (radio_off); [color] when null.
  final Color? offColor;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final on = color ?? nc.primary;
    return SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: checked ? on : (offColor ?? on), width: 2),
          ),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 150),
            scale: checked ? 1 : 0,
            child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: on)),
          ),
        ),
      ),
    );
  }
}

/// MaterialCheckBox (app:buttonTint @color/checkbox_tint): 18dp box with 2dp corners, primary
/// with a white tick when checked, a 2dp #B8BEC8 frame when not; [size] is the touch box.
class NativeCheckBox extends StatelessWidget {
  const NativeCheckBox({super.key, required this.checked, this.size = 32, this.offColor = const Color(0xFFB8BEC8)});

  final bool checked;
  final double size;
  final Color offColor;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: checked ? nc.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
            border: checked ? null : Border.all(color: offColor, width: 2),
          ),
          child: checked ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
        ),
      ),
    );
  }
}

/// Big bottom action (MaterialButton 56dp, primary, 28dp corners, white 16sp bold) with 16dp side
/// margins; disabled at alpha 0.4 like the native screens.
class NativeBottomAction extends StatelessWidget {
  const NativeBottomAction({super.key, required this.label, required this.onPressed, this.enabled = true, this.margin});

  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: margin ?? const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: Material(
              color: nc.primary,
              borderRadius: BorderRadius.circular(28),
              child: InkWell(
                borderRadius: BorderRadius.circular(28),
                splashColor: const Color(0x33FFFFFF),
                onTap: enabled ? onPressed : null,
                child: Center(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// sheet_confirm.xml: SheetTitle (18sp bold) centered, message 15sp text_primary, then
/// GrayPillButton Cancel | PillButton OK (48dp, 16dp apart). "Quit merging?" / "Discard changes?".
/// True when [ok] is tapped. [danger] paints OK red (native sheets are all blue).
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String ok,
  String? cancel,
  bool danger = false,
}) async {
  final s = S.of(context);
  final result = await showAppSheet<bool>(
    context,
    builder: (sheet) {
      final nc = NC.of(sheet);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary)),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: nc.textPrimary)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: NativePillButton(label: cancel ?? s.t('cancel'), gray: true, onPressed: () => Navigator.pop(sheet, false)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: NativePillButton(
                      label: ok,
                      color: danger ? nc.danger : null,
                      onPressed: () => Navigator.pop(sheet, true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return result == true;
}

/// sheet_number_input.xml (FileSheets.askText / askNumber): SheetTitle, 50dp bg_rename_field
/// (surface, 1.5dp primary, 10dp) with a clear ×, a 12sp hint line, Cancel | OK.
Future<String?> _askSheet(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  required bool number,
  required String? Function(String text) validate,
}) async {
  final s = S.of(context);
  final controller = TextEditingController(text: initial);
  controller.selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  String? error;
  final value = await showAppSheet<String>(
    context,
    builder: (sheet) => StatefulBuilder(
      builder: (sheetContext, setSheet) {
        final nc = NC.of(sheetContext);
        void submit() {
          final text = controller.text.trim();
          final problem = validate(text);
          if (problem != null) {
            setSheet(() => error = problem);
            return;
          }
          Navigator.pop(sheet, text);
        }

        final line = error ?? hint;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: nc.textPrimary)),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 50,
                  padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
                  decoration: BoxDecoration(
                    color: nc.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: nc.primary, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          autofocus: true,
                          maxLines: 1,
                          maxLength: number ? 5 : 120,
                          keyboardType: number ? TextInputType.number : TextInputType.text,
                          textInputAction: TextInputAction.done,
                          cursorColor: nc.primary,
                          style: TextStyle(fontSize: 15, color: nc.textPrimary),
                          decoration: const InputDecoration(border: InputBorder.none, isCollapsed: true, counterText: ''),
                          onChanged: (_) {
                            if (error != null) setSheet(() => error = null);
                          },
                          onSubmitted: (_) => submit(),
                        ),
                      ),
                      NativeIconButton(
                        ND.icClose,
                        size: 36,
                        padding: 10,
                        tint: nc.textSecondary,
                        onPressed: () => setSheet(() {
                          controller.clear();
                          error = null;
                        }),
                      ),
                    ],
                  ),
                ),
                if (line != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(line, style: TextStyle(fontSize: 12, color: error != null ? nc.danger : nc.textSecondary)),
                  ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(child: NativePillButton(label: s.t('cancel'), gray: true, onPressed: () => Navigator.pop(sheet))),
                    const SizedBox(width: 16),
                    Expanded(child: NativePillButton(label: s.t('ok'), onPressed: submit)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  controller.dispose();
  return value;
}

/// One-line text question (file name, part name…).
Future<String?> askText(BuildContext context, {required String title, String initial = '', String? hint}) async {
  final s = S.of(context);
  final empty = s.t('renameEmpty');
  final value = await _askSheet(
    context,
    title: title,
    initial: initial,
    number: false,
    validate: (text) => text.isEmpty ? empty : null,
  );
  if (value == null || value.isEmpty) return null;
  return value;
}

/// A whole number between [min] and [max] typed by the person.
Future<int?> askNumber(BuildContext context, {required String title, required int initial, int min = 1, int max = 999}) async {
  final value = await _askSheet(
    context,
    title: title,
    initial: '$initial',
    hint: '$min – $max',
    number: true,
    validate: (text) => int.tryParse(text) == null ? '$min – $max' : null,
  );
  if (value == null) return null;
  final number = int.tryParse(value);
  if (number == null) return null;
  return number.clamp(min, max);
}

/// Full-screen dark "Enter text" screen (dialog_text_entry.xml: #E6000000, X and ✓ 48dp at the
/// top corners, centered 20sp white text, "Clear" pill at the bottom end). Returns the text, or
/// null when closed.
Future<String?> enterText(BuildContext context, {String initial = ''}) {
  return Navigator.of(context).push<String>(
    PageRouteBuilder<String>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, _, _) => _TextEntryPage(initial: initial),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _TextEntryPage extends StatefulWidget {
  const _TextEntryPage({required this.initial});

  final String initial;

  @override
  State<_TextEntryPage> createState() => _TextEntryPageState();
}

class _TextEntryPageState extends State<_TextEntryPage> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection.collapsed(offset: widget.initial.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: const Color(0xE6000000),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 8,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  cursorColor: Colors.white,
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: s.t('enterText'),
                    hintStyle: const TextStyle(color: Color(0x99FFFFFF), fontSize: 20),
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              top: 4,
              start: 4,
              child: NativeIconButton(
                ND.icClose,
                size: 48,
                padding: 12,
                tint: Colors.white,
                tooltip: s.t('cancel'),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            PositionedDirectional(
              top: 4,
              end: 4,
              child: NativeIconButton(
                ND.icCheck,
                size: 48,
                padding: 12,
                tint: Colors.white,
                tooltip: s.t('ok'),
                onPressed: () => Navigator.pop(context, _controller.text),
              ),
            ),
            PositionedDirectional(
              bottom: 14,
              end: 14,
              child: Material(
                color: const Color(0xFF3A3D44),
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: () => _controller.clear(),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    child: Text(
                      s.t('clearText'),
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A grid whose tiles can be long-pressed and dragged to a new place. [footer] is an extra tile
/// at the end (e.g. "Add pages") that does not move.
class ReorderGrid extends StatelessWidget {
  const ReorderGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.onReorder,
    this.itemKey,
    this.crossAxisCount = 2,
    this.childAspectRatio = 0.72,
    this.footer,
    this.padding = const EdgeInsets.all(16),
    this.spacing = 12,
    this.enabled = true,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final void Function(int from, int to) onReorder;
  final Key Function(int index)? itemKey;
  final int crossAxisCount;
  final double childAspectRatio;
  final Widget? footer;
  final EdgeInsets padding;
  final double spacing;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - padding.horizontal - spacing * (crossAxisCount - 1)) / crossAxisCount;
        final height = width / childAspectRatio;
        final nc = NC.of(context);
        return GridView.builder(
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: itemCount + (footer == null ? 0 : 1),
          itemBuilder: (context, index) {
            if (index >= itemCount) return footer!;
            final tile = itemBuilder(context, index);
            if (!enabled) return KeyedSubtree(key: itemKey?.call(index), child: tile);
            return LongPressDraggable<int>(
              key: itemKey?.call(index),
              data: index,
              feedback: SizedBox(
                width: width * 1.05,
                height: height * 1.05,
                child: Material(
                  elevation: 8,
                  color: Colors.transparent,
                  child: Opacity(opacity: 0.95, child: itemBuilder(context, index)),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.25, child: tile),
              child: DragTarget<int>(
                onWillAcceptWithDetails: (details) => details.data != index,
                onAcceptWithDetails: (details) => onReorder(details.data, index),
                builder: (context, candidates, rejected) => AnimatedScale(
                  duration: const Duration(milliseconds: 120),
                  scale: candidates.isEmpty ? 1 : 0.95,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: candidates.isEmpty ? Colors.transparent : nc.primary, width: 2),
                    ),
                    child: tile,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// item_scan_add.xml: 8:10 bg_add_pages tile (surface_variant, 1dp #E1E5EC, 4dp corners) with
/// ic_insert_page 28dp and "Add pages" 14sp, both text_secondary.
class AddTile extends StatelessWidget {
  const AddTile({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: AspectRatio(
        aspectRatio: 8 / 10,
        child: Material(
          color: nc.surfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: const BorderSide(color: Color(0xFFE1E5EC)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                NativeIcon(ND.icInsertPage, size: 28, tint: nc.textSecondary),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: nc.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Round × on a page tile: bg_remove_dark (#B3000000 oval, 26dp, ic_close white with 7dp padding).
/// [bubble] = bg_delete_bubble (#6B7280 with a 1.5dp white ring, 24dp, 6dp padding).
class RemoveDot extends StatelessWidget {
  const RemoveDot({super.key, required this.onTap, this.icon = Icons.close_rounded, this.bubble = false});

  final VoidCallback onTap;

  /// Kept for callers; the native ic_close is drawn.
  final IconData icon;
  final bool bubble;

  @override
  Widget build(BuildContext context) {
    final size = bubble ? 24.0 : 26.0;
    return Material(
      color: bubble ? const Color(0xFF6B7280) : const Color(0xB3000000),
      shape: bubble ? const CircleBorder(side: BorderSide(color: Colors.white, width: 1.5)) : const CircleBorder(),
      elevation: bubble ? 4 : 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Padding(
            padding: EdgeInsets.all(bubble ? 6 : 7),
            child: const NativeIcon(ND.icClose, tint: Colors.white),
          ),
        ),
      ),
    );
  }
}
