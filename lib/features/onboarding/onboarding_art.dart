import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/native_art.dart';
import '../../widgets/vector_art.dart';

/// Colours of the Android onboarding (bg_onboarding, bg_onboarding_fade, dot_off).
abstract final class OnboardingColors {
  static const top = Color(0xFF3A3A3C);
  static const center = Color(0xFF232325);
  static const bottom = Color(0xFF0E0E10);
  static const dotOff = Color(0xFF4A4F58);
}

/// The mock-ups always use the light colours: the phone screen is white in both themes.
abstract final class _Mock {
  static const primary = Color(0xFF0A5FD9);
  static const ink = Color(0xFF1B1F2A);
  static const secondary = Color(0xFF8E949E);
  static const hint = Color(0xFFB3B8C2);
  static const field = Color(0xFFF3F5F9);
  static const skeleton = Color(0xFFEDF1F6);
  static const bookmark = Color(0xFFFFC107);
  static const red = Color(0xFFE53935);
}

/// bg_onboarding: dark vertical gradient plus a soft white glow at 35 % height.
class OnboardingBackground extends StatelessWidget {
  const OnboardingBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [OnboardingColors.top, OnboardingColors.center, OnboardingColors.bottom],
        ),
      ),
      child: _Glow(),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // radial gradient, centre (0.5, 0.35), radius 420 dp
        final shortest = box.biggest.shortestSide;
        final radius = shortest <= 0 ? 1.0 : 420 / shortest;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.3),
              radius: radius,
              colors: const [Color(0x33FFFFFF), Color(0x00FFFFFF)],
            ),
          ),
        );
      },
    );
  }
}

/// One onboarding page: the phone mock-up, floating tiles, the bottom fade and the title,
/// laid out like res/layout/page_onboarding_1..3.xml.
class OnboardingPageArt extends StatelessWidget {
  const OnboardingPageArt({super.key, required this.index, required this.title, required this.enter});

  final int index;
  final String title;

  /// 0 → 1 when the page becomes the current one.
  final Animation<double> enter;

  @override
  Widget build(BuildContext context) {
    final phone = AnimatedBuilder(
      animation: enter,
      builder: (context, child) {
        final t = Curves.easeOut.transform((enter.value / (450 / 520)).clamp(0.0, 1.0));
        return Opacity(
          opacity: 0.4 + 0.6 * t,
          child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
        );
      },
      child: switch (index) {
        0 => const _Phone(width: 236, height: 460, angle: -9, child: _ListScreen()),
        1 => const _Phone(width: 236, height: 460, angle: -7, child: _EditorScreen()),
        _ => const _Phone(width: 252, height: 470, angle: 0, child: _ResumeScreen()),
      },
    );
    return ClipRect(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(top: 80, left: 0, right: 0, child: Center(child: phone)),
          ..._floaters(),
          // bg_onboarding_fade: the lower part darkens so the title stays readable
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 340,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x000E0E10), Color(0xCC0E0E10), Color(0xFF0E0E10)],
                ),
              ),
            ),
          ),
          PositionedDirectional(
            start: 24,
            end: 24,
            bottom: 112,
            child: AnimatedBuilder(
              animation: enter,
              builder: (context, child) {
                final t = Curves.easeOut.transform(((enter.value - 120 / 520) / (400 / 520)).clamp(0.0, 1.0));
                return Opacity(
                  opacity: t,
                  child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
                );
              },
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700, height: 1.25),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _floaters() {
    switch (index) {
      case 0:
        return const [
          PositionedDirectional(
            start: 30,
            top: 265,
            child: _Floating(duration: 1700, child: _Tile(art: NativeArt.tileWord, size: 70, angle: -8)),
          ),
          PositionedDirectional(
            end: 36,
            top: 220,
            child: _Floating(duration: 1500, delay: 300, child: _Tile(art: NativeArt.tilePdf, size: 76, angle: 6)),
          ),
          PositionedDirectional(
            start: 58,
            top: 420,
            child: _Floating(duration: 1900, delay: 150, child: _Tile(art: NativeArt.tilePpt, size: 66, angle: -6)),
          ),
          PositionedDirectional(
            end: 30,
            top: 400,
            child: _Floating(duration: 1600, delay: 450, child: _Tile(art: NativeArt.tileExcel, size: 64, angle: 8)),
          ),
        ];
      case 1:
        return const [
          PositionedDirectional(
            end: 60,
            top: 100,
            child: _Floating(duration: 1600, child: _Tile(art: NativeArt.tileText, size: 58)),
          ),
          PositionedDirectional(
            start: 56,
            top: 380,
            child: _Floating(
              duration: 1800,
              delay: 250,
              child: PhysicalModel(
                color: Colors.transparent,
                shape: BoxShape.circle,
                elevation: 6,
                child: VectorArt(NativeArt.penCircle, viewport: NativeArt.penCircleViewport, width: 52, height: 52),
              ),
            ),
          ),
          PositionedDirectional(
            end: 20,
            top: 330,
            child: _Floating(duration: 2000, delay: 100, distance: 8 * 0.6, child: _EditorBar()),
          ),
        ];
      default:
        return const [
          PositionedDirectional(
            end: 34,
            top: 270,
            child: _Floating(duration: 1700, distance: 8 * 0.7, child: _ResumeChip()),
          ),
          PositionedDirectional(
            start: 30,
            end: 30,
            top: 350,
            child: _Floating(duration: 2100, delay: 200, distance: 8 * 0.6, child: _ResumeBar()),
          ),
        ];
    }
  }
}

/// Floats up and down forever (Ext.kt startFloating: 0 → −distance, reverse, ease in-out).
class _Floating extends StatefulWidget {
  const _Floating({required this.duration, this.delay = 0, this.distance = 8, required this.child});

  final int duration;
  final int delay;
  final double distance;
  final Widget child;

  @override
  State<_Floating> createState() => _FloatingState();
}

class _FloatingState extends State<_Floating> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: Duration(milliseconds: widget.duration));
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Transform.translate(offset: Offset(0, -widget.distance * _curve.value), child: child),
      child: widget.child,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.art, required this.size, this.angle = 0});

  final List<VPath> art;
  final double size;
  final double angle;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle * 3.141592653589793 / 180,
      child: VectorArt(art, width: size, height: size),
    );
  }
}

/// bg_phone_frame + bg_phone_screen, rotated by [angle] degrees.
class _Phone extends StatelessWidget {
  const _Phone({required this.width, required this.height, required this.angle, required this.child});

  final double width;
  final double height;
  final double angle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle * 3.141592653589793 / 180,
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: const Color(0xFF101114),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFF3A3C42), width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ColoredBox(
            color: Colors.white,
            // the mock-up is a fixed drawing: keep it LTR and unscaled by the font size setting
            child: MediaQuery.withNoTextScaling(
              child: Directionality(textDirection: TextDirection.ltr, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// MockBar / MockBarDark: 4 dp bars with 5 dp space above.
class _Bar extends StatelessWidget {
  const _Bar({this.width, this.dark = false});

  final double? width;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      width: width ?? double.infinity,
      height: 4,
      margin: const EdgeInsets.only(top: 5),
      decoration: BoxDecoration(
        color: dark ? _Mock.hint.withValues(alpha: 0.55) : _Mock.skeleton,
        borderRadius: dark ? null : BorderRadius.circular(3),
      ),
    );
    return Align(alignment: Alignment.centerLeft, child: bar);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(text, style: const TextStyle(color: _Mock.ink, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}

// ---------------------------------------------------------------- page 1: the file list

class _MockRow {
  const _MockRow(this.icon, this.name, this.meta, this.bookmarked);

  final List<VPath> icon;
  final String name;
  final String meta;
  final bool bookmarked;
}

const _mockRows = [
  _MockRow(NativeArt.catWord, 'Project Proposal_2024 Version.docx', 'Just now · 3.2MB', true),
  _MockRow(NativeArt.catPdf, 'Research Paper_The Future of AI.pdf', '12 minutes ago · 150KB', true),
  _MockRow(NativeArt.catExcel, 'Recent work arrangement.xlsx', '3 hours ago · 3.2MB', false),
  _MockRow(NativeArt.catPpt, 'Product data analysis.ppt', '08/25/2024 · 1.8MB', false),
  _MockRow(NativeArt.catWord, 'Annual Financial Report_Q4.docx', '04/30/2024 · 67KB', true),
  _MockRow(NativeArt.catTxt, 'Dune battle.txt', '10/28/2023 · 2.5MB', false),
  _MockRow(NativeArt.catImage, 'Image file_architecture.img', '09/10/2023 · 450KB', false),
  _MockRow(NativeArt.catPdf, 'Market Analysis Report_Q2.pdf', '07/19/2023 · 4.7MB', true),
  _MockRow(NativeArt.catWord, 'Training Plan_H2 2023.pptx', '05/05/2023 · 600KB', false),
];

class _ListScreen extends StatelessWidget {
  const _ListScreen();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 7, right: 16),
          child: Text(
            '12:30',
            textAlign: TextAlign.right,
            style: TextStyle(color: _Mock.ink, fontSize: 8, fontWeight: FontWeight.w700),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6, left: 12),
          child: Row(
            children: [
              NativeIcon(ND.icMenu, size: 12, tint: _Mock.ink),
              SizedBox(width: 6),
              Text('All Document Reader', style: TextStyle(color: _Mock.ink, fontSize: 10, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Container(
          height: 24,
          margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(color: _Mock.field, borderRadius: BorderRadius.circular(22)),
          child: Row(
            children: [
              const NativeIcon(ND.icSearch, size: 10, tint: _Mock.secondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  s.t('searchForFiles'),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(color: _Mock.hint, fontSize: 8),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 12),
          child: Row(
            children: [
              Text(s.t('recent'), style: const TextStyle(color: _Mock.primary, fontSize: 8.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 18),
              Text(s.t('bookmarks'), style: const TextStyle(color: _Mock.hint, fontSize: 8.5)),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 18,
            height: 2,
            margin: const EdgeInsets.only(left: 14, top: 2),
            decoration: BoxDecoration(color: _Mock.primary, borderRadius: BorderRadius.circular(3)),
          ),
        ),
        const SizedBox(height: 4),
        for (final row in _mockRows) _MockRowView(row: row),
      ],
    );
  }
}

class _MockRowView extends StatelessWidget {
  const _MockRowView({required this.row});

  final _MockRow row;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 4),
        child: Row(
          children: [
            VectorArt(row.icon, width: 18, height: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _Mock.ink, fontSize: 9.5, fontWeight: FontWeight.w700),
                  ),
                  Text(row.meta, maxLines: 1, style: const TextStyle(color: _Mock.secondary, fontSize: 7.5)),
                ],
              ),
            ),
            NativeIcon(
              row.bookmarked ? ND.icBookmark : ND.icBookmarkBorder,
              size: 11,
              tint: row.bookmarked ? _Mock.bookmark : _Mock.hint,
            ),
            const SizedBox(width: 6),
            const NativeIcon(ND.icMoreVert, size: 11, tint: _Mock.hint),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- page 2: the PDF editor

class _EditorScreen extends StatelessWidget {
  const _EditorScreen();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NativeIcon(ND.icBack, size: 14, tint: _Mock.ink),
          SizedBox(height: 14),
          _TitleCard(),
          _Heading('Current Economic Landscape'),
          _Bar(dark: true),
          _Bar(dark: true),
          _Bar(dark: true, width: 170),
          _Bar(dark: true),
          _Bar(dark: true, width: 120),
          _Heading('Technology'),
          _Bar(dark: true),
          _Bar(dark: true),
          _Bar(dark: true, width: 150),
          _Bar(dark: true),
          _Heading('Healthcare'),
          _Bar(dark: true),
          _Bar(dark: true, width: 160),
          _Bar(dark: true),
          _Bar(dark: true, width: 100),
        ],
      ),
    );
  }
}

class _TitleCard extends StatelessWidget {
  const _TitleCard();

  @override
  Widget build(BuildContext context) {
    const title = TextStyle(color: _Mock.ink, fontSize: 15, fontWeight: FontWeight.w700);
    return Material(
      color: Colors.white,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Market ', style: title),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6E6FF),
                    border: Border.all(color: _Mock.primary),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: const Text('Outlook', style: title),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('Q2-Q3 2024', style: TextStyle(color: _Mock.primary, fontSize: 8)),
            ),
            Container(width: 44, height: 1.5, color: _Mock.red),
          ],
        ),
      ),
    );
  }
}

/// White rounded tool bar: A, underline, strike-through, pen.
class _EditorBar extends StatelessWidget {
  const _EditorBar();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      child: const SizedBox(
        width: 170,
        height: 46,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Expanded(child: Center(child: Text('A', style: TextStyle(color: _Mock.ink, fontSize: 20)))),
              Expanded(child: Center(child: NativeIcon(ND.icUnderline, size: 20, tint: _Mock.primary))),
              Expanded(child: Center(child: NativeIcon(ND.icStrike, size: 20, tint: _Mock.primary))),
              Expanded(child: Center(child: NativeIcon(ND.icPen, size: 20, tint: _Mock.primary))),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- page 3: the resume template

class _ResumeScreen extends StatelessWidget {
  const _ResumeScreen();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const NativeIcon(ND.icBack, size: 14, tint: _Mock.ink),
              const Spacer(),
              // MockIcon: 16 dp, 10 dp apart
              for (final icon in const [ND.icUndo, ND.icRedo, ND.icDownload, ND.icShare])
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: NativeIcon(icon, size: 16, tint: _Mock.ink),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: _Mock.primary, width: 1.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const VectorArt(NativeArt.avatar, viewport: NativeArt.avatarViewport, width: 76, height: 76),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Riley K. Morgan', style: TextStyle(color: _Mock.ink, fontSize: 11, fontWeight: FontWeight.w700)),
                      Text('Product Manager', style: TextStyle(color: _Mock.secondary, fontSize: 7.5)),
                      _EndBar(90),
                      _EndBar(100),
                      _EndBar(70),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Heading('Contact'),
                      _Bar(width: 60),
                      _Bar(width: 50),
                      _Bar(width: 64),
                      _Bar(width: 56),
                      _Heading('Education'),
                      _Bar(width: 50),
                      _Bar(width: 64),
                      _Bar(width: 44),
                      _Heading('Skills'),
                      _Bar(width: 58),
                      _Bar(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  flex: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Heading('Experience'),
                      _Bar(),
                      _Bar(),
                      _Bar(width: 90),
                      _Bar(),
                      _Bar(width: 110),
                      _Bar(),
                      _Bar(),
                      _Bar(width: 80),
                      _Bar(),
                      _Bar(width: 100),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A light bar lined up on the right (the column under the name has gravity="end").
class _EndBar extends StatelessWidget {
  const _EndBar(this.width);

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 4,
      margin: const EdgeInsets.only(top: 5),
      decoration: BoxDecoration(color: _Mock.skeleton, borderRadius: BorderRadius.circular(3)),
    );
  }
}

/// "Resume|" in a blue selection box.
class _ResumeChip extends StatelessWidget {
  const _ResumeChip();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(3),
        side: const BorderSide(color: _Mock.primary, width: 1.5),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text('Resume|', style: TextStyle(color: _Mock.primary, fontSize: 22, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

/// White rounded tool bar: image, crop, Aa (serif italic), AA, A with a red colour bar.
class _ResumeBar extends StatelessWidget {
  const _ResumeBar();

  @override
  Widget build(BuildContext context) {
    const glyph = TextStyle(color: _Mock.ink, fontSize: 20);
    return Material(
      color: Colors.white,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Expanded(child: Center(child: NativeIcon(ND.icImageLine, size: 24, tint: _Mock.ink))),
              const Expanded(child: Center(child: NativeIcon(ND.icCrop, size: 24, tint: _Mock.ink))),
              const Expanded(
                child: Center(
                  child: Text('Aa', style: TextStyle(color: _Mock.ink, fontSize: 20, fontFamily: 'serif', fontStyle: FontStyle.italic)),
                ),
              ),
              const Expanded(child: Center(child: Text('AA', style: glyph))),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('A', style: glyph),
                      Container(
                        width: 16,
                        height: 3,
                        decoration: BoxDecoration(color: _Mock.red, borderRadius: BorderRadius.circular(1)),
                      ),
                    ],
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
