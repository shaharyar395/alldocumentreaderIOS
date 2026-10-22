import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // like the Android SplashActivity: 2600 ms
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    if (!mounted) return;
    final scope = AppScope.of(context);
    // like the Android app: loading screen → App Open ad on every start (the first one too);
    // it waits only while the ad is still loading (see AdService.showAppOpen)
    if (!scope.settings.premium) {
      await scope.ads.showAppOpen();
    }
    if (!mounted) return;
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    // back does nothing on the splash (SplashActivity ignores it)
    return const PopScope(canPop: false, child: SplashView());
  }
}

/// The Android activity_splash.xml: surface colour, the bg_splash_deco art (1:1, full width,
/// 90 % opacity) at the bottom, the 96 dp logo at 32 % of the height, the 24 sp bold app name
/// 16 dp below, the 15 sp subtitle 6 dp below that, and the 96 x 5 dp sliding bar 110 dp above
/// the bottom. [animateIn]: logo, name and subtitle fade in and rise 12 dp (450 ms, 80 ms
/// apart) like SplashActivity.animateIn — for the first screen shown at launch.
class SplashView extends StatefulWidget {
  const SplashView({super.key, this.animateIn = false});

  final bool animateIn;

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 610),
    value: widget.animateIn ? 0 : 1,
  );

  /// The i-th view: 80 ms × i delay, then 450 ms (of the 610 ms controller).
  late final List<CurvedAnimation> _steps = [
    for (var i = 0; i < 3; i++)
      CurvedAnimation(parent: _in, curve: Interval(80.0 * i / 610, (80.0 * i + 450) / 610, curve: Curves.easeInOut)),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.animateIn) _in.forward();
  }

  @override
  void dispose() {
    for (final step in _steps) {
      step.dispose();
    }
    _in.dispose();
    super.dispose();
  }

  Widget _rise(int i, Widget child) {
    final curve = _steps[i];
    return AnimatedBuilder(
      animation: curve,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(offset: Offset(0, 12 * (1 - curve.value)), child: child),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return ColoredBox(
      color: c.surface,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final logoTop = (box.maxHeight - 96) * 0.32;
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: 0.9,
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: NativeIcon(ND.bgSplashDeco),
                    ),
                  ),
                ),
                Positioned(
                  left: 32,
                  right: 32,
                  top: logoTop,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _rise(0, const AppLogo(size: 96)),
                      const SizedBox(height: 16),
                      _rise(
                        1,
                        Text(
                          'All Document Reader',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: c.textPrimary),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _rise(2, const _Subtitle()),
                    ],
                  ),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 110,
                  child: Center(child: SlidingProgress()),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      S.of(context).t('splashSubtitleView'),
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 15, color: NC.of(context).textSecondary),
    );
  }
}
