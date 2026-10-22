import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';

/// Pieces shared by Get Premium and Start Free Trial, like the Android PaywallUi.

/// PaywallUi.gradientText: the text painted with a left → right gradient across its own width.
class PaywallGradientText extends StatelessWidget {
  const PaywallGradientText(this.text, {super.key, required this.colors, required this.style, this.textAlign});

  final String text;
  final List<Color> colors;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => LinearGradient(colors: colors).createShader(rect),
      child: Text(text, textAlign: textAlign, style: style.copyWith(color: Colors.white)),
    );
  }
}

/// PaywallUi.revealClose: the X (ic_close, 44dp, padding 12dp, #B3FFFFFF) shows up after
/// [delay] with a 300 ms fade, like the original.
class PaywallRevealClose extends StatefulWidget {
  const PaywallRevealClose({super.key, required this.delay, required this.onTap, this.tooltip});

  final Duration delay;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  State<PaywallRevealClose> createState() => _PaywallRevealCloseState();
}

class _PaywallRevealCloseState extends State<PaywallRevealClose> {
  bool _shown = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final button = InkResponse(
      onTap: _shown ? widget.onTap : null,
      radius: 22,
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(child: NativeIcon(ND.icClose, size: 20, tint: Color(0xB3FFFFFF))),
      ),
    );
    return IgnorePointer(
      ignoring: !_shown,
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: widget.tooltip == null ? button : Tooltip(message: widget.tooltip, child: button),
      ),
    );
  }
}

/// The top-end "Restore" text button of the paywall screens (40dp, padding 10dp, 13sp).
class PaywallRestoreButton extends StatelessWidget {
  const PaywallRestoreButton({super.key, required this.label, required this.onTap, required this.color});

  final String label;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 40,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(color: color, fontSize: 13)),
      ),
    );
  }
}

/// The 52dp Continue button of the paywall screens: a 28dp-corner gradient (bg_paywall_continue
/// / bg_trial_continue), a light streak (bg_btn_shine) sweeping across it every 1.1 s
/// (PaywallUi.shine), the 18sp bold label, an optional arrow at the end, a spinner while busy.
class PaywallContinueButton extends StatefulWidget {
  const PaywallContinueButton({
    super.key,
    required this.label,
    required this.colors,
    required this.onTap,
    this.busy = false,
    this.arrow = false,
  });

  final String label;
  final List<Color> colors;
  final VoidCallback? onTap;
  final bool busy;
  final bool arrow;

  @override
  State<PaywallContinueButton> createState() => _PaywallContinueButtonState();
}

class _PaywallContinueButtonState extends State<PaywallContinueButton> with SingleTickerProviderStateMixin {
  late final AnimationController _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  Timer? _start;

  @override
  void initState() {
    super.initState();
    _start = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _shine.repeat();
    });
  }

  @override
  void dispose() {
    _start?.cancel();
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(28));
    return SizedBox(
      height: 52,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(gradient: LinearGradient(colors: widget.colors), borderRadius: radius),
          child: InkWell(
            onTap: widget.onTap,
            splashColor: const Color(0x33FFFFFF),
            highlightColor: const Color(0x1AFFFFFF),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    // 36dp streak, 12dp taller above and below, rotated 20°, from -72 to width+36
                    AnimatedBuilder(
                      animation: _shine,
                      builder: (context, child) {
                        final t = Curves.easeInOutSine.transform(_shine.value);
                        final x = -72 + (width + 36 + 72) * t;
                        return Positioned(left: x, top: -12, bottom: -12, width: 36, child: child!);
                      },
                      child: Transform.rotate(
                        angle: 20 * math.pi / 180,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [Color(0x00FFFFFF), Color(0x40FFFFFF), Color(0x00FFFFFF)]),
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: widget.busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 52),
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                              ),
                            ),
                    ),
                    if (widget.arrow && !widget.busy)
                      const PositionedDirectional(
                        end: 20,
                        top: 15,
                        child: NativeIcon(ND.icArrowRightW, size: 22, tint: Colors.white),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
