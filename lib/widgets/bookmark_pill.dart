import 'package:flutter/material.dart';

import '../l10n/s.dart';
import '../native/native_drawables.dart';
import '../native/native_icon.dart';
import '../native/native_shapes.dart';

OverlayEntry? _current;

/// Dark rounded message near the bottom after tapping a bookmark icon — "Bookmarked" /
/// "Bookmark removed" — like the Android app's BookmarkPill (shown 1.5 s, pops in, fades out).
void showBookmarkPill(BuildContext context, {required bool added}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final text = S.of(context).t(added ? 'bookmarked' : 'bookmarkRemoved');
  final old = _current;
  if (old != null && old.mounted) old.remove();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.paddingOf(context).bottom + 100,
      child: IgnorePointer(
        child: Center(
          child: _Pill(
            added: added,
            text: text,
            onDone: () {
              if (entry.mounted) entry.remove();
              if (identical(_current, entry)) _current = null;
            },
          ),
        ),
      ),
    ),
  );
  _current = entry;
  overlay.insert(entry);
}

class _Pill extends StatefulWidget {
  const _Pill({required this.added, required this.text, required this.onDone});

  final bool added;
  final String text;
  final VoidCallback onDone;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))..forward();
  late final CurvedAnimation _pop = CurvedAnimation(parent: _in, curve: const _Overshoot(1.4));
  double _opacity = 1;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _opacity = 0);
      Future<void>.delayed(const Duration(milliseconds: 230), widget.onDone);
    });
  }

  @override
  void dispose() {
    _pop.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 220),
      child: FadeTransition(
        opacity: _in,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1).animate(_pop),
          child: Material(
            color: NS.bgBmPill(context).color,
            elevation: 6,
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              height: 46,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 16, end: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NativeIcon(widget.added ? ND.icBmPillOn : ND.icBmPillOff, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// android.view.animation.OvershootInterpolator(tension).
class _Overshoot extends Curve {
  const _Overshoot(this.tension);

  final double tension;

  @override
  double transformInternal(double t) {
    final x = t - 1;
    return x * x * ((tension + 1) * x + tension) + 1;
  }
}
