import 'package:flutter/material.dart';

import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../widgets/file_row.dart';

/// Shared native-looking pieces of the file screens (Android activity_file_list.xml,
/// activity_directories.xml, activity_storage_browser.xml, activity_search.xml,
/// activity_pick_file.xml, layout_list_state.xml and the FileSheets bottom sheets).

/// 44dp toolbar ImageButton (10dp padding, borderless ripple, tinted text_primary).
class BarIconButton extends StatelessWidget {
  const BarIconButton({super.key, required this.drawable, required this.onTap, this.tooltip, this.padding = 10, this.size = 44, this.tint});

  final NDrawable drawable;
  final VoidCallback? onTap;
  final String? tooltip;
  final double padding;
  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return RowIconButton(
      drawable: drawable,
      onTap: onTap,
      tooltip: tooltip,
      size: size,
      padding: padding,
      tint: tint ?? NC.of(context).textPrimary,
    );
  }
}

/// The 56dp white toolbar of the native list screens: ‹ back (44dp), bold title, actions.
class NativeTopBar extends StatelessWidget {
  const NativeTopBar({
    super.key,
    this.title,
    this.titleWidget,
    this.titleSize = 20,
    this.onBack,
    this.actions = const [],
    this.height = 56,
    this.endPadding = 6,
    this.backPadding = 10,
  });

  final String? title;
  final Widget? titleWidget;
  final double titleSize;

  /// Back button; defaults to Navigator.maybePop.
  final VoidCallback? onBack;
  final List<Widget> actions;
  final double height;
  final double endPadding;
  final double backPadding;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: 4, end: endPadding),
        child: Row(
          children: [
            BarIconButton(
              drawable: ND.icBack,
              padding: backPadding,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onTap: onBack ?? () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: titleWidget ??
                  Text(
                    title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// The 56dp search bar that replaces the toolbar: rounded bg_search_field (40dp, surface_variant,
/// 22dp corners) with the hint "Search for files…", the ⊗ clear button, and a bold "Cancel".
class NativeSearchBar extends StatelessWidget {
  const NativeSearchBar({
    super.key,
    required this.controller,
    required this.hint,
    required this.cancelLabel,
    required this.onCancel,
    required this.onChanged,
    this.focusNode,
    this.autofocus = true,
    this.showClear = true,
    this.cancelBold = true,
    this.cancelHeight,
  });

  final TextEditingController controller;
  final String hint;
  final String cancelLabel;
  final VoidCallback onCancel;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;
  final bool autofocus;

  /// The ⊗ button inside the field (activity_file_list); the storage browser / picker have none.
  final bool showClear;
  final bool cancelBold;
  final double? cancelHeight;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final hasText = controller.text.isNotEmpty;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 40,
                decoration: NS.bgSearchField(context),
                padding: EdgeInsetsDirectional.only(start: 14, end: showClear ? 4 : 14),
                child: Row(
                  children: [
                    Expanded(
                      child: NativeTextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: autofocus,
                        hint: hint,
                        textInputAction: TextInputAction.search,
                        onChanged: onChanged,
                      ),
                    ),
                    if (showClear && hasText)
                      RowIconButton(
                        drawable: ND.icClearCircle,
                        tint: c.textHint,
                        size: 32,
                        padding: 8,
                        onTap: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                  ],
                ),
              ),
            ),
            NativeTextAction(label: cancelLabel, onTap: onCancel, bold: cancelBold, height: cancelHeight),
          ],
        ),
      ),
    );
  }
}

/// An EditText with background="@null": 15sp text_primary, text_hint hint, one line.
class NativeTextField extends StatelessWidget {
  const NativeTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.fontSize = 15,
  });

  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      maxLines: 1,
      textInputAction: textInputAction,
      cursorColor: c.primary,
      style: TextStyle(fontSize: fontSize, color: c.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: fontSize, color: c.textHint),
        hintMaxLines: 1,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        isCollapsed: true,
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

/// A TextView button with selectableItemBackground ("Cancel" next to a search field).
class NativeTextAction extends StatelessWidget {
  const NativeTextAction({super.key, required this.label, required this.onTap, this.bold = true, this.color, this.height});

  final String label;
  final VoidCallback onTap;
  final bool bold;
  final Color? color;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return SizedBox(
      height: height,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(fontSize: 15, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color ?? c.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

/// TabLayout of the native screens: 44dp, scrollable from the start, 15sp bold labels,
/// tab_indicator (24 x 3dp primary, 2dp corners) under the selected one, no ripple.
class NativeTabStrip extends StatelessWidget implements PreferredSizeWidget {
  const NativeTabStrip({
    super.key,
    required this.labels,
    this.controller,
    this.onTap,
    this.selectedColor,
    this.tabPadding = 16,
  });

  final List<String> labels;
  final TabController? controller;
  final ValueChanged<int>? onTap;

  /// tabSelectedTextColor (primary in file lists, text_primary in Directories).
  final Color? selectedColor;
  final double tabPadding;

  @override
  Size get preferredSize => const Size.fromHeight(44);

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    const style = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    return Container(
      height: 44,
      color: c.surface,
      alignment: AlignmentDirectional.centerStart,
      child: TabBar(
        controller: controller,
        onTap: onTap,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.symmetric(horizontal: tabPadding),
        labelColor: selectedColor ?? c.primary,
        unselectedLabelColor: c.textSecondary,
        labelStyle: style,
        unselectedLabelStyle: style,
        dividerColor: Colors.transparent,
        dividerHeight: 0,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        indicator: _TabIndicator(c.primary),
        indicatorSize: TabBarIndicatorSize.tab,
        tabs: [for (final label in labels) Tab(height: 44, text: label)],
      ),
    );
  }
}

/// res/drawable/tab_indicator.xml: a 24 x 3dp bar with 2dp corners, centred at the tab's bottom.
class _TabIndicator extends Decoration {
  const _TabIndicator(this.color);

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _TabIndicatorPainter(color);
}

class _TabIndicatorPainter extends BoxPainter {
  _TabIndicatorPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final rect = Rect.fromLTWH(offset.dx + (size.width - 24) / 2, offset.dy + size.height - 3, 24, 3);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)), Paint()..color = color);
  }
}

/// layout_list_state.xml "emptyView": ic_empty_state (150 x 130dp) + "No files found", 80dp down.
class NativeEmptyState extends StatelessWidget {
  const NativeEmptyState({super.key, required this.text, this.top = 80});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NativeIcon(ND.icEmptyState, width: 150, height: 130),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// fragment_dir_list.xml "emptyView": ic_empty_state (160 x 140dp), bold title and an optional
/// grey line, 100dp down with 40dp side padding.
class NativeDirEmptyState extends StatelessWidget {
  const NativeDirEmptyState({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 100, 40, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const NativeIcon(ND.icEmptyState, width: 160, height: 140),
          const SizedBox(height: 4),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
          if (sub != null) ...[
            const SizedBox(height: 6),
            Text(sub, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// layout_list_state.xml "loadingView": the paper plane bobbing 10dp up and down (700ms) and
/// "Loading files…", 120dp down.
class NativeLoadingState extends StatefulWidget {
  const NativeLoadingState({super.key, required this.text});

  final String text;

  @override
  State<NativeLoadingState> createState() => _NativeLoadingStateState();
}

class _NativeLoadingStateState extends State<NativeLoadingState> with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 120),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _bob,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, -10 * Curves.easeInOut.transform(_bob.value)),
              child: child,
            ),
            child: const NativeIcon(ND.icPaperPlane, size: 64),
          ),
          const SizedBox(height: 10),
          Text(widget.text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary)),
        ],
      ),
    );
  }
}

/// The 36dp primary ProgressBar in the middle of a list.
class NativeProgress extends StatelessWidget {
  const NativeProgress({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 36,
        height: 36,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: CircularProgressIndicator(strokeWidth: 3, color: NC.of(context).primary),
        ),
      ),
    );
  }
}

/// One action of a 60dp selection bar (icon 22dp + small label), dimmed when nothing is chosen.
class SelectBarAction {
  const SelectBarAction({required this.drawable, required this.label, required this.onTap});

  final NDrawable drawable;
  final String label;
  final VoidCallback onTap;
}

/// The selection bar at the bottom (activity_file_list "selectActions", activity_recycle_bin
/// "bottomBar"): surface, 8dp elevation, slides up in 200ms.
class NativeSelectBar extends StatefulWidget {
  const NativeSelectBar({
    super.key,
    required this.actions,
    required this.enabled,
    this.labelSize = 12,
    this.labelGap = 3,
  });

  final List<SelectBarAction> actions;
  final bool enabled;
  final double labelSize;
  final double labelGap;

  @override
  State<NativeSelectBar> createState() => _NativeSelectBarState();
}

class _NativeSelectBarState extends State<NativeSelectBar> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 200))..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(_in),
      child: Material(
        color: c.surface,
        elevation: 8,
        child: SizedBox(
          height: 60,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.4,
            child: Row(
              children: [
                for (final action in widget.actions)
                  Expanded(
                    child: InkWell(
                      onTap: action.onTap,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          NativeIcon(action.drawable, size: 22, tint: c.textPrimary),
                          SizedBox(height: widget.labelGap),
                          Text(action.label, maxLines: 1, style: TextStyle(fontSize: widget.labelSize, color: c.textPrimary)),
                        ],
                      ),
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

/// PillButton / GrayPillButton: 48dp, 24dp corners, 16sp bold; primary + white or btn_gray +
/// text_primary.
class NativePillButton extends StatelessWidget {
  const NativePillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.gray = false,
    this.textColor,
    this.height = 48,
    this.radius = 24,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool gray;
  final Color? textColor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final bg = gray ? c.btnGray : c.primary;
    final fg = textColor ?? (gray ? c.textPrimary : c.white);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Material(
        color: onPressed == null ? bg.withValues(alpha: bg.a * 0.4) : bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          splashColor: gray ? const Color(0x1F000000) : Colors.white24,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// style/SheetTitle: 18sp bold text_primary.
TextStyle sheetTitleStyle(BuildContext context, {double size = 18}) =>
    TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: NC.of(context).textPrimary);

/// MaterialRadioButton tinted with radio_tint (primary on, radio_off off): 20dp ring, 10dp dot.
class NativeRadio extends StatelessWidget {
  const NativeRadio({super.key, required this.checked});

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
          width: 20,
          height: 20,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: checked ? 10 : 0,
            height: checked ? 10 : 0,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ),
      ),
    );
  }
}

/// 36dp ImageButton with a 10/11dp-padded ic_close (sheet close buttons, top end, 8dp margin).
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, required this.onTap, this.tooltip});

  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return PositionedDirectional(
      top: 8,
      end: 8,
      child: RowIconButton(drawable: ND.icClose, size: 40, padding: 11, tint: NC.of(context).textSecondary, tooltip: tooltip, onTap: onTap),
    );
  }
}

/// The surface_variant handle at the top of ActionSheet (36 x 4dp, 2dp corners, 10dp down).
class NativeSheetHandle extends StatelessWidget {
  const NativeSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10),
        decoration: NS.bgBottomSheetHandle(context),
      ),
    );
  }
}

/// A row of ActionSheet (item_sheet_action.xml): 52dp, 22dp icon tinted text_primary, 15sp label.
class NativeSheetAction extends StatelessWidget {
  const NativeSheetAction({super.key, required this.drawable, required this.label, required this.onTap});

  final NDrawable drawable;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 22, end: 20),
          child: Row(
            children: [
              NativeIcon(drawable, size: 22, tint: c.textPrimary),
              const SizedBox(width: 18),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: c.textPrimary))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Header of ActionSheet (sheet_actions.xml): handle, 36dp icon, 16sp bold title (middle
/// ellipsis), 12sp subtitle, then a divider.
class NativeSheetHeader extends StatelessWidget {
  const NativeSheetHeader({super.key, required this.icon, required this.title, this.subtitle});

  final Widget icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final sub = subtitle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NativeSheetHandle(),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 14, 20, 10),
          child: Row(
            children: [
              icon,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiddleEllipsisText(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.textPrimary)),
                    if (sub != null && sub.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(sub, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: c.divider),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// sheet_confirm.xml: centred title (18sp bold), 15sp message, Cancel (gray) / OK (primary).
/// Returns true on OK.
Future<bool> showNativeConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String okLabel,
  required String cancelLabel,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, textAlign: TextAlign.center, style: sheetTitleStyle(sheet)),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: NC.of(sheet).textPrimary)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: NativePillButton(label: cancelLabel, gray: true, onPressed: () => Navigator.pop(sheet, false))),
                const SizedBox(width: 16),
                Expanded(child: NativePillButton(label: okLabel, onPressed: () => Navigator.pop(sheet, true))),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

/// The RecyclerView layout animation (anim/layout_list_fade + item_fade_in): every row fades
/// in and rises 30% of its height in 320ms (decelerate), each one 38ms after the previous one —
/// only when the list is first filled (or re-sorted).
class ListAnimGate {
  int generation = 0;
  bool _filled = false;
  DateTime? _until;

  /// Call while building with whether the list has rows: the first fill plays the animation.
  void fill(bool hasRows) {
    if (_filled || !hasRows) return;
    _filled = true;
    _until = DateTime.now().add(const Duration(milliseconds: 900));
  }

  /// scheduleLayoutAnimation() after a filter / folder change.
  void replay() {
    generation++;
    _filled = true;
    _until = DateTime.now().add(const Duration(milliseconds: 900));
  }

  bool get playing {
    final until = _until;
    return until != null && DateTime.now().isBefore(until);
  }

  Widget wrap(int index, Widget child) => ListFadeIn(key: ValueKey<int>(generation), index: index, play: playing, child: child);
}

class ListFadeIn extends StatefulWidget {
  const ListFadeIn({super.key, required this.index, required this.play, required this.child});

  final int index;
  final bool play;
  final Widget child;

  @override
  State<ListFadeIn> createState() => _ListFadeInState();
}

class _ListFadeInState extends State<ListFadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  late final CurvedAnimation _curve = CurvedAnimation(parent: _c, curve: Curves.decelerate);

  @override
  void initState() {
    super.initState();
    if (!widget.play) {
      _c.value = 1;
      return;
    }
    final delay = Duration(milliseconds: (widget.index.clamp(0, 16) * 38.4).round());
    Future<void>.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

/// item_folder.xml: 64dp, ic_folder_blue (38dp), 15sp bold name, "N files" (12sp), › text_hint.
class FolderRow extends StatelessWidget {
  const FolderRow({super.key, required this.name, required this.meta, required this.onTap});

  final String name;
  final String meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 12),
            child: Row(
              children: [
                const NativeIcon(ND.icFolderBlue, size: 38),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary)),
                      const SizedBox(height: 3),
                      Text(meta, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ],
                  ),
                ),
                NativeIcon(ND.icChevronRight, size: 20, tint: c.textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
