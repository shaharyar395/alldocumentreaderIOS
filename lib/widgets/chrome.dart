import 'package:flutter/material.dart';

import '../native/native_colors.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';
import '../native/native_shapes.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});

  final double size;

  /// The app logo: the Android app's ic_logo vector (same art as the launcher icon).
  @override
  Widget build(BuildContext context) => NativeIcon(ND.icLogo, size: size);
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
    final Color bg = warning ? const Color(0xFFE36B2C) : (dark ? const Color(0xFF3C4043) : const Color(0xFFF1F3F4));
    final Color fg = warning ? Colors.white : (dark ? const Color(0xFFE8EAED) : const Color(0xFF202124));
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
              borderRadius: BorderRadius.circular(28),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: fg, fontSize: 14, height: 1.3, fontWeight: FontWeight.w400, decoration: TextDecoration.none),
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
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14, decoration: TextDecoration.none),
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
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: NC.of(context).toolsSection),
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
