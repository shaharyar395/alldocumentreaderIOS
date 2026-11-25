import 'package:flutter/material.dart';

import '../native/native_colors.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';
import '../native/native_shapes.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});

  final double size;

  /// The document icon, shown whole. Splash, launch, and the app icon use this artwork.
  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/app_logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

/// The Android app's ic_crown (gold crown with a red check). With [color] it is tinted
/// in one colour (app:tint).
class CrownIcon extends StatelessWidget {
  const CrownIcon({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => NativeIcon(ND.icCrown, size: size, tint: color);
}

/// The splash / welcome-back loading bar: a primary thumb sliding back and forth on a
/// progress_track pill (splash: 96 x 5 dp with a 22 dp thumb; welcome back: 88 x 4 dp, 28 dp).
class SlidingProgress extends StatefulWidget {
  const SlidingProgress({super.key, this.width = 96, this.height = 5, this.thumb = 22});

  final double width;
  final double height;
  final double thumb;

  @override
  State<SlidingProgress> createState() => _SlidingProgressState();
}

class _SlidingProgressState extends State<SlidingProgress> with SingleTickerProviderStateMixin {
  // Android splash: a 22 dp thumb in a 96 x 5 dp track, 750 ms each way, ease in-out, back and forth
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  )..repeat(reverse: true);
  late final CurvedAnimation _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        // bg_progress_track with a bg_progress_bar thumb
        decoration: NS.bgProgressTrack(context),
        child: AnimatedBuilder(
          animation: curve,
          builder: (context, _) => Align(
            alignment: Alignment(-1 + 2 * curve.value, 0),
            child: Container(width: widget.thumb, height: widget.height, decoration: NS.bgProgressBar(context)),
          ),
        ),
      ),
    );
  }
}

OverlayEntry? _toastEntry;

/// A short message like the Android app's Toast.makeText(…, LENGTH_SHORT): a rounded bubble
/// near the bottom of the screen that fades in, stays 2 s and fades out. [warning] = orange.
void showToast(BuildContext context, String message, {bool warning = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final previous = _toastEntry;
  if (previous != null && previous.mounted) previous.remove();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _FadingMessage(
      hold: const Duration(milliseconds: 2000),
      fadeIn: const Duration(milliseconds: 200),
      fadeOut: const Duration(milliseconds: 250),
      onDone: () {
        if (entry.mounted) entry.remove();
        if (identical(_toastEntry, entry)) _toastEntry = null;
      },
      builder: (context, opacity) => _Toast(message: message, warning: warning, opacity: opacity),
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
}

class _Toast extends StatelessWidget {
  const _Toast({required this.message, required this.warning, required this.opacity});

  final String message;
  final bool warning;
  final Animation<double> opacity;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = NC.of(context);
    final Color bg = warning ? c.danger : (dark ? c.surfaceVariant : c.navbarBg);
    final Color fg = warning ? Colors.white : (dark ? c.textPrimary : Colors.white);
    final media = MediaQuery.of(context);
    return Positioned(
      left: 24,
      right: 24,
      bottom: media.viewPadding.bottom + media.viewInsets.bottom + 64,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: opacity,
          child: Center(
            child: Material(
              color: bg,
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Poppins', color: fg, fontSize: 14, height: 1.3, fontWeight: FontWeight.w400, decoration: TextDecoration.none),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

OverlayEntry? _pillEntry;

/// The Android app's TopPill: a 36 dp rounded message near the top of the screen, 14 sp bold
/// white text with an 18 dp white icon, elevation 6; fades in (150 ms), stays 1.6 s, fades out
/// (250 ms). Default = the orange "warn" pill with ⓘ 28 dp below the status bar (e.g. "No valid
/// subscription found."). [icon] null = no icon; [decoration] null = bg_top_pill_warn.
void showTopPill(
  BuildContext context,
  String message, {
  NDrawable? icon = ND.icAlertCircle,
  double topMargin = 28,
  Decoration? decoration,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final background = decoration ?? NS.bgTopPillWarn(context);
  final previous = _pillEntry;
  if (previous != null && previous.mounted) previous.remove();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _FadingMessage(
      hold: const Duration(milliseconds: 1600),
      fadeIn: const Duration(milliseconds: 150),
      fadeOut: const Duration(milliseconds: 250),
      onDone: () {
        if (entry.mounted) entry.remove();
        if (identical(_pillEntry, entry)) _pillEntry = null;
      },
      builder: (context, opacity) => Positioned(
        top: MediaQuery.paddingOf(context).top + topMargin,
        left: 16,
        right: 16,
        child: IgnorePointer(
          child: FadeTransition(
            opacity: opacity,
            child: Center(
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                height: 36,
                padding: EdgeInsetsDirectional.only(start: icon != null ? 12 : 16, end: 16),
                decoration: background is BoxDecoration
                    ? background.copyWith(
                        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3))],
                      )
                    : background,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      NativeIcon(icon, size: 18, tint: Colors.white),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'Poppins', color: Colors.white, fontWeight: FontWeight.w500, fontSize: 14, decoration: TextDecoration.none),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ),
        ),
      ),
    ),
  );
  _pillEntry = entry;
  overlay.insert(entry);
}

/// Fades its child in, keeps it [hold], fades it out and calls [onDone].
class _FadingMessage extends StatefulWidget {
  const _FadingMessage({
    required this.hold,
    required this.fadeIn,
    required this.fadeOut,
    required this.onDone,
    required this.builder,
  });

  final Duration hold;
  final Duration fadeIn;
  final Duration fadeOut;
  final VoidCallback onDone;

  /// Builds the message: a Positioned (inside the overlay's Stack) whose content fades with
  /// the given opacity.
  final Widget Function(BuildContext context, Animation<double> opacity) builder;

  @override
  State<_FadingMessage> createState() => _FadingMessageState();
}

class _FadingMessageState extends State<_FadingMessage> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this, duration: widget.fadeIn);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await _fade.forward().orCancel;
      await Future<void>.delayed(widget.hold);
      if (!mounted) return;
      _fade.duration = widget.fadeOut;
      await _fade.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _fade);
}

Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: builder(context),
      );
    },
  );
}

class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      // sheet_actions.xml: 36 x 4 dp bg_bottom_sheet_handle, 10 dp from the top
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: NS.bgBottomSheetHandle(context),
      ),
    );
  }
}

/// The Android app's empty list state (layout_list_state.xml): the ic_empty_state picture
/// (150 x 130 dp) and the message in 14 sp text_secondary; [body] (if any) below it.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, required this.body, this.icon = Icons.folder_open_rounded});

  final String title;
  final String body;

  /// Kept for callers; the native picture is always ic_empty_state.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NativeIcon(ND.icEmptyState, width: 150, height: 130),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(body, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, height: 1.35, color: c.textHint)),
          ],
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: NC.of(context).textSecondary),
      ),
    );
  }
}

class ToolTile extends StatelessWidget {
  const ToolTile({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Material(
      color: c.surfaceVariant,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w500, color: c.textPrimary, fontSize: 13),
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

// ------------------------------------------------------------------ "Plum deck" pieces (1.0.35+)

/// Space under the last list item (Android @dimen/nav_bar_clearance). Android 1.0.75: the tab bar
/// sits under the page and the banner, not over the content, so only a small gap is left.
const double kNavBarClearance = 16;

/// TopBarBack: the 48 dp back button, a 40 dp accent_container circle with ic_back (text_primary).
class DsTopBack extends StatelessWidget {
  const DsTopBack({super.key, this.onTap, this.tint});

  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return DsCircleButton(
      fill: c.accentContainer,
      icon: ND.icBack,
      tint: tint ?? c.textPrimary,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      mirrorInRtl: true,
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
    );
  }
}

/// TopBarAction: a 48 dp target with a 40 dp surface circle and a hairline divider ring; the icon
/// is tinted text_primary unless [tint] is given (pass [keepColors] for coloured art like the crown).
class DsTopAction extends StatelessWidget {
  const DsTopAction({super.key, required this.icon, required this.onTap, this.tint, this.keepColors = false, this.tooltip, this.iconPadding = 14});

  final NDrawable icon;
  final VoidCallback? onTap;
  final Color? tint;
  final bool keepColors;
  final String? tooltip;
  final double iconPadding;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return DsCircleButton(
      fill: c.surface,
      ring: c.divider,
      icon: icon,
      tint: keepColors ? null : (tint ?? c.textPrimary),
      tooltip: tooltip,
      onTap: onTap,
      iconPadding: iconPadding,
    );
  }
}

/// A 48 dp touch target with a 40 dp circle ([fill], optional 1 dp [ring]) and a centred icon.
/// Pressing scales it to 0.96 (ds_a_press_scale).
class DsCircleButton extends StatefulWidget {
  const DsCircleButton({
    super.key,
    required this.fill,
    required this.icon,
    required this.onTap,
    this.ring,
    this.tint,
    this.tooltip,
    this.size = 48,
    this.circle = 40,
    this.iconPadding = 14,
    this.mirrorInRtl = false,
  });

  /// Back arrows point the reading direction in Arabic, Persian and Urdu.
  final bool mirrorInRtl;
  final Color fill;
  final Color? ring;
  final NDrawable icon;
  final Color? tint;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double circle;
  final double iconPadding;

  @override
  State<DsCircleButton> createState() => _DsCircleButtonState();
}

class _DsCircleButtonState extends State<DsCircleButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final inset = (widget.size - widget.circle) / 2;
    Widget button = Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerCancel: (_) => setState(() => _down = false),
      onPointerUp: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 90),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Padding(
            padding: EdgeInsets.all(inset),
            child: Material(
              color: widget.fill,
              shape: CircleBorder(side: widget.ring == null ? BorderSide.none : BorderSide(color: widget.ring!, width: 1)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                splashColor: c.rowPressed,
                highlightColor: c.rowPressed.withValues(alpha: 0.4),
                child: Padding(
                  padding: EdgeInsets.all(widget.iconPadding - inset),
                  child: widget.mirrorInRtl && Directionality.of(context) == TextDirection.rtl
                      ? Transform.flip(flipX: true, child: NativeIcon(widget.icon, tint: widget.tint))
                      : NativeIcon(widget.icon, tint: widget.tint),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final tip = widget.tooltip;
    if (tip != null) button = Tooltip(message: tip, child: button);
    return Semantics(button: true, child: button);
  }
}

/// ScreenTitle: 22 sp medium text_primary (the big title of the main tabs).
TextStyle dsScreenTitle(BuildContext context) =>
    TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: NC.of(context).textPrimary, height: 1.25);

/// TopBarTitle: 18 sp medium text_primary.
TextStyle dsTopBarTitle(BuildContext context) =>
    TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: NC.of(context).textPrimary);

/// Widget.DocReader.Tabs text tabs: 15 sp medium, text_primary when selected (text_secondary
/// otherwise) over an 18 x 4 dp accent pill that slides between the tabs; 10 dp side padding,
/// 48 dp high, no ripple.
class DsTextTabs extends StatelessWidget {
  const DsTextTabs({super.key, required this.labels, required this.index, required this.onSelect});

  final List<String> labels;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < labels.length; i++)
            Semantics(
              selected: i == index,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 180),
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: i == index ? c.textPrimary : c.textSecondary,
                        ),
                        child: Text(labels[i], textAlign: TextAlign.center),
                      ),
                      Positioned(
                        bottom: 4,
                        child: AnimatedScale(
                          scale: i == index ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          child: Container(
                            width: 18,
                            height: 4,
                            decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Section label (13 sp medium text_secondary, sentence case), 16 dp from the sides.
class DsSectionLabel extends StatelessWidget {
  const DsSectionLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(16, 18, 16, 8)});

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: NC.of(context).textSecondary)),
    );
  }
}
