import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';

/// Shared native-look pieces of the Settings / Premium / Reader screens.

/// The native 44dp ImageButton (padding 10dp → a 24dp icon) with a borderless ripple.
class NativeIconButton extends StatelessWidget {
  const NativeIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tint,
    this.size = 44,
    this.padding = 10,
    this.tooltip,
    this.mirrorInRtl = false,
  });

  final NDrawable icon;
  final VoidCallback? onTap;
  final Color? tint;
  final double size;
  final double padding;
  final String? tooltip;

  /// Back arrows / chevrons point the reading direction in Arabic, Persian and Urdu.
  final bool mirrorInRtl;

  @override
  Widget build(BuildContext context) {
    Widget child = NativeIcon(icon, size: size - padding * 2, tint: tint);
    if (mirrorInRtl) child = NativeMirror(child: child);
    Widget button = InkResponse(
      onTap: onTap,
      radius: size / 2,
      child: SizedBox(width: size, height: size, child: Center(child: child)),
    );
    final tip = tooltip;
    if (tip != null && tip.isNotEmpty) button = Tooltip(message: tip, child: button);
    return button;
  }
}

/// The back ImageButton of every native screen (ic_back, 44dp, padding 10dp, tint).
class NativeBackButton extends StatelessWidget {
  const NativeBackButton({super.key, this.tint, this.onTap});

  final Color? tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return NativeIconButton(
      icon: ND.icBack,
      tint: tint ?? NC.of(context).textPrimary,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      mirrorInRtl: true,
      onTap: onTap ?? () => Navigator.maybePop(context),
    );
  }
}

/// Flips a direction icon (back arrow, chevron) horizontally in right-to-left languages.
class NativeMirror extends StatelessWidget {
  const NativeMirror({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Directionality.of(context) != TextDirection.rtl) return child;
    return Transform.flip(flipX: true, child: child);
  }
}

/// An Android RadioButton (Material Components, minWidth/minHeight 0): a 20dp ring with a
/// 2dp stroke and a 10dp dot when checked, in a 32dp box; tint @color/radio_tint.
class NativeRadio extends StatelessWidget {
  const NativeRadio({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final nc = NC.of(context);
    final color = checked ? nc.primary : nc.radioOff;
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
          child: AnimatedScale(
            scale: checked ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// bg_apply_btn: the native blue 24dp-corner button (#B7CFF3 when disabled) with a white bold
/// label; [height] 50dp by default.
class NativeApplyButton extends StatelessWidget {
  const NativeApplyButton({
    super.key,
    required this.label,
    required this.onTap,
    this.height = 50,
    this.fontSize = 17,
    this.leading,
  });

  final String label;
  final VoidCallback? onTap;
  final double height;
  final double fontSize;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.w700),
    );
    final lead = leading;
    return Material(
      color: enabled ? NC.of(context).primary : const Color(0xFFB7CFF3),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Center(
            child: lead == null
                ? text
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [lead, const SizedBox(width: 8), Flexible(child: text)],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Light status-bar icons over a dark / blue top (native Theme.DocReader.BlueBar, Premium,
/// Trial). Only the status bar is touched; when the page goes away the theme's own style
/// (as set in app.dart) comes back, because pages without an AnnotatedRegion don't reset it.
class NativeLightStatusBar extends StatefulWidget {
  const NativeLightStatusBar({super.key, required this.child});

  final Widget child;

  @override
  State<NativeLightStatusBar> createState() => _NativeLightStatusBarState();
}

class _NativeLightStatusBarState extends State<NativeLightStatusBar> {
  bool _dark = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dark = Theme.of(context).brightness == Brightness.dark;
  }

  @override
  void dispose() {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: _dark ? Brightness.dark : Brightness.light,
      ),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: widget.child,
    );
  }
}
