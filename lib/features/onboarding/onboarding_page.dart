import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../l10n/s.dart';
import 'onboarding_art.dart';

/// First-launch onboarding like the Android app (OnboardingActivity): three dark pages with a
/// mock phone and a big title, page dots bottom-left, "Next" / "Start" bottom-right, no Skip.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> with SingleTickerProviderStateMixin {
  static const _pageCount = 3;
  static const _primary = Color(0xFF0A5FD9);

  final _controller = PageController();
  int _index = 0;
  bool _finishing = false;

  /// Small entrance animation of the page that becomes visible (phone 450 ms, title 400 ms
  /// after 120 ms). The first page starts finished, like the Android app.
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 520), value: 1);

  @override
  void dispose() {
    _enter.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_index < _pageCount - 1) {
      await _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      return;
    }
    if (_finishing) return;
    _finishing = true;
    await AppScope.of(context).settings.completeOnboarding();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final titles = [s.t('onbTitle1'), s.t('onbTitle2'), s.t('onbTitle3')];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: OnboardingColors.bottom,
        body: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Stack(
            children: [
              const Positioned.fill(child: OnboardingBackground()),
              PageView.builder(
                controller: _controller,
                itemCount: _pageCount,
                onPageChanged: (value) {
                  setState(() => _index = value);
                  _enter.forward(from: 0);
                },
                itemBuilder: (context, index) => OnboardingPageArt(
                  index: index,
                  title: titles[index],
                  enter: index == _index ? _enter : kAlwaysCompleteAnimation,
                ),
              ),
              // dots: the current one 18 dp wide, the others 6 dp
              PositionedDirectional(
                start: 28,
                bottom: 52,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < _pageCount; i++)
                      Container(
                        width: i == _index ? 18 : 6,
                        height: 6,
                        margin: const EdgeInsetsDirectional.only(end: 8),
                        decoration: BoxDecoration(
                          color: i == _index ? _primary : OnboardingColors.dotOff,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
              PositionedDirectional(
                end: 24,
                bottom: 32,
                child: SizedBox(
                  height: 46,
                  child: FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      backgroundColor: _primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(96, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    child: Text(_index == _pageCount - 1 ? s.t('start') : s.t('next')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
