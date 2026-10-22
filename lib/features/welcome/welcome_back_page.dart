import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/chrome.dart';

/// "Welcome back…" with the sliding blue bar, like the Android WelcomeBackActivity: shown when
/// the user returns to the app, closes itself after 1800 ms (then the App Open ad), back is ignored.
class WelcomeBackPage extends StatefulWidget {
  const WelcomeBackPage({super.key});

  @override
  State<WelcomeBackPage> createState() => _WelcomeBackPageState();
}

class _WelcomeBackPageState extends State<WelcomeBackPage> {
  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    // activity_welcome_back.xml: surface, the bg_splash_deco art at the bottom (1:1, 90 %),
    // "Welcome back…" (19 sp bold) at 46 % of the height, the 88 x 4 dp bar (28 dp thumb)
    // 14 dp below it
    final c = NC.of(context);
    return PopScope(
      canPop: false,
      child: Material(
        color: c.surface,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              const textHeight = 26.0;
              final top = (box.maxHeight - textHeight) * 0.46;
              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Opacity(
                      opacity: 0.9,
                      child: AspectRatio(aspectRatio: 1, child: NativeIcon(ND.bgSplashDeco)),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    top: top,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: textHeight,
                          child: Center(
                            child: Text(
                              S.of(context).t('welcomeBackDots'),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: c.textPrimary),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const SlidingProgress(width: 88, height: 4, thumb: 28),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
