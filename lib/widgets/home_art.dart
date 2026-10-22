import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../native/native_drawables.dart';
import '../native/native_icon.dart';

/// Small pictures of the Android app's home screen, drawn from its own vector drawables
/// (ic_cat_all, ic_empty_state, ic_paper_plane) so no image assets are needed.

/// The "All files" icon (ic_cat_all), as in the access dialog.
class AllFilesGlyph extends StatelessWidget {
  const AllFilesGlyph({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) => NativeIcon(ND.icCatAll, size: size);
}

/// The empty-state picture (ic_empty_state, 150 x 130 dp, fitCenter) used above "Empty" and the
/// access-missing hint.
class EmptyArt extends StatelessWidget {
  const EmptyArt({super.key, this.width = 150, this.height = 130});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => NativeIcon(ND.icEmptyState, width: width, height: height);
}

/// "Loading files…": a paper plane (ic_paper_plane) that drifts and tilts like the Android app's
/// first-scan view (±10 dp sideways, ±5 dp up/down, ±8°, 900 ms, back and forth).
class PaperPlaneLoader extends StatefulWidget {
  const PaperPlaneLoader({super.key, this.size = 64});

  final double size;

  @override
  State<PaperPlaneLoader> createState() => _PaperPlaneLoaderState();
}

class _PaperPlaneLoaderState extends State<PaperPlaneLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _drift,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_drift.value) * 2 - 1; // -1 … 1
        return Transform.translate(
          offset: Offset(10 * t, -5 * t),
          child: Transform.rotate(angle: 8 * t * math.pi / 180, child: child),
        );
      },
      child: NativeIcon(ND.icPaperPlane, size: widget.size),
    );
  }
}
