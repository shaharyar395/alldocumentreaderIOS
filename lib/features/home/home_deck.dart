import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../data/reading_progress.dart';
import '../../features/files/device_files.dart';
import '../../features/files/file_actions.dart';
import '../../features/reader/reader_page.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/app_analytics.dart';

/// The stacked card "deck" on top of the home screen (fragment_home.xml deck, HomeFragment
/// renderDeck / switchDeck / DeckSwipe, "Plum deck" 1.0.35+): two cards peek out under the front
/// card. The front card is "Continue reading" (the file read last in the reader, its page and a
/// progress bar; it opens the file at that page) or "Recently added" (the newest files, with a
/// "+N" badge of new ones). Drag the front card sideways past 30% of its width to bring up the
/// other card; with only one card it moves a little and comes back. Two dots show which card is
/// on top when both exist.
class HomeDeck extends StatefulWidget {
  const HomeDeck({super.key, required this.fresh, required this.onRecentlyAdded});

  /// New files since the Recently added list was last opened (the "+N" badge).
  final int fresh;
  final VoidCallback onRecentlyAdded;

  @override
  State<HomeDeck> createState() => _HomeDeckState();
}

class _HomeDeckState extends State<HomeDeck> with TickerProviderStateMixin {
  /// true = Continue reading on top, false = Recently added.
  bool _continueOnTop = true;

  /// When the shown reading position was saved: a newer one puts Continue reading back on top.
  int _entryTime = 0;

  /// Drag of the front card (dp), and the fly-off / spring-back animation.
  double _dx = 0;
  late final AnimationController _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<double>? _settleAnim;

  /// The deck fans in once when the home screen first shows (DsMotion.fanIn).
  late final AnimationController _fan = AnimationController(vsync: this, duration: const Duration(milliseconds: 520))..forward();

  @override
  void initState() {
    super.initState();
    ReadingProgress.changed.addListener(_onChanged);
    _settle.addListener(() {
      final anim = _settleAnim;
      if (anim != null) setState(() => _dx = anim.value);
    });
  }

  @override
  void dispose() {
    ReadingProgress.changed.removeListener(_onChanged);
    _settle.dispose();
    _fan.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _animations => !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  /// The last-read file, if it is still in the library and on disk.
  (ReadingEntry, DocEntry)? _continue() {
    final entry = ReadingProgress.last();
    if (entry == null) return null;
    final library = AppScope.of(context).library;
    DocEntry? doc;
    for (final e in library.entries) {
      if (!e.inBin && e.relativePath == entry.ref) {
        doc = e;
        break;
      }
    }
    if (doc == null || !File(doc.fullPath).existsSync()) return null;
    return (entry, doc);
  }

  Future<void> _openContinue(ReadingEntry entry, DocEntry doc) async {
    logEvent('continue_reading_open', {'page': '${entry.page + 1}'});
    logEvent('continue_reading_tapped');
    if (!opensInApp(doc.name)) {
      await openEntry(context, doc);
      return;
    }
    final library = AppScope.of(context).library;
    if (!await ensureLocalFiles(context, [doc])) return;
    await library.markOpened(doc);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReaderPage(entry: doc, startPage: entry.page)));
  }

  void _animateTo(double target, {required VoidCallback? then, Curve curve = Curves.fastOutSlowIn, int ms = 220}) {
    _settle.duration = Duration(milliseconds: ms);
    _settleAnim = Tween<double>(begin: _dx, end: target).animate(CurvedAnimation(parent: _settle, curve: curve));
    _settle.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      then?.call();
    });
  }

  void _swap() {
    setState(() {
      _continueOnTop = !_continueOnTop;
      _dx = 0;
      _settleAnim = null;
    });
    if (_animations) _fan.forward(from: 0.55);
  }

  /// The top card flies off to [direction] (-1 left, 1 right) and the other card comes up.
  void _switch(double direction, double width) {
    if (!_animations) {
      _swap();
      return;
    }
    _animateTo(direction * width * 1.15, then: _swap);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final cont = _continue();
    final both = cont != null;
    if (cont != null && cont.$1.time != _entryTime) {
      _entryTime = cont.$1.time;
      _continueOnTop = true;
    }
    final showContinue = both && _continueOnTop;
    final front = (cont != null && _continueOnTop)
        ? _ContinueCard(entry: cont.$1, doc: cont.$2, onTap: () => _openContinue(cont.$1, cont.$2))
        : _RecentCard(fresh: widget.fresh, onTap: () {
            logEvent('recently_added_clicked');
            widget.onRecentlyAdded();
          });
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final fraction = width <= 0 ? 0.0 : (_dx.abs() / width).clamp(0.0, 1.0);
              return AnimatedBuilder(
                animation: _fan,
                builder: (context, child) {
                  double rise(double from, double to) {
                    final t = Curves.easeOutCubic.transform(((_fan.value - from) / (to - from)).clamp(0.0, 1.0));
                    return t;
                  }

                  final back = rise(0.0, 0.6), middle = rise(0.15, 0.75), top = rise(0.3, 1.0);
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 26,
                        right: 26,
                        top: 16,
                        bottom: 0,
                        child: Opacity(
                          opacity: back,
                          child: Transform.translate(
                            offset: Offset(0, (1 - back) * 14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: c.deckBack, borderRadius: BorderRadius.circular(22)),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 13,
                        right: 13,
                        top: 8,
                        bottom: 8,
                        child: Opacity(
                          opacity: middle,
                          child: Transform.translate(
                            offset: Offset(0, (1 - middle) * 14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: c.deckMiddle, borderRadius: BorderRadius.circular(22)),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Opacity(
                          opacity: top * (1 - fraction * 0.35),
                          child: Transform.translate(
                            offset: Offset(_dx, (1 - top) * 14),
                            child: Transform.rotate(
                              angle: (width <= 0 ? 0 : _dx / width * 6) * math.pi / 180,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
                child: Semantics(
                  customSemanticsActions: both
                      ? {CustomSemanticsAction(label: s.t('dsSwipeDeck')): () => _swap()}
                      : const {},
                  child: GestureDetector(
                    onHorizontalDragStart: (_) => _settle.stop(),
                    onHorizontalDragUpdate: (d) => setState(() => _dx += both ? d.primaryDelta! : d.primaryDelta! * 0.25),
                    onHorizontalDragEnd: (d) {
                      if (both && _dx.abs() > width * 0.3) {
                        _switch(_dx < 0 ? -1 : 1, width);
                      } else {
                        _animateTo(0, then: null, curve: Curves.easeOutBack, ms: 200);
                      }
                    },
                    child: front,
                  ),
                ),
              );
            },
          ),
        ),
        if (both)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(active: showContinue),
                const SizedBox(width: 6),
                _Dot(active: !showContinue),
              ],
            ),
          ),
      ],
    );
  }
}

/// bg_dot_active (18 x 6 dp primary pill) / bg_dot_inactive (6 dp dot_off circle).
class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: active ? 18 : 6,
      height: 6,
      decoration: BoxDecoration(color: active ? c.primary : c.dotOff, borderRadius: BorderRadius.circular(3)),
    );
  }
}

/// The front card frame (ds_a_deck_front: deck_front, 22 dp corners, white ripple, at least
/// 128 dp high, padding 18 / 16 / 14 / 16).
class _DeckFront extends StatelessWidget {
  const _DeckFront({required this.onTap, required this.label, required this.child});

  final VoidCallback onTap;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: c.deckFront,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: const Color(0x33FFFFFF),
          highlightColor: const Color(0x14FFFFFF),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 128),
            child: Padding(padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 14, 16), child: child),
          ),
        ),
      ),
    );
  }
}

/// The round go button on a deck card (ds_a_deck_go: 44 dp accent_soft circle, ic_back turned
/// to point forward, tinted navbar_pill_text).
class _GoButton extends StatelessWidget {
  const _GoButton();

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Container(
      width: 44,
      height: 44,
      margin: const EdgeInsetsDirectional.only(start: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
      child: Transform.rotate(angle: rtl ? 0 : math.pi, child: NativeIcon(ND.icBack, tint: c.navbarPillText)),
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry, required this.doc, required this.onTap});

  final ReadingEntry entry;
  final DocEntry doc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final page = s.t('dsPageOf', {'page': '${entry.page + 1}', 'count': '${entry.pageCount}'});
    final soft = TextStyle(fontSize: 12, color: c.deckTextSoft, height: 1.3);
    return _DeckFront(
      onTap: onTap,
      label: '${s.t('dsContinueReading')}, ${doc.name}, $page',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(s.t('dsContinueReading'), maxLines: 1, overflow: TextOverflow.ellipsis, style: soft)),
              Text(s.t('dsPercentRead', {'percent': '${(entry.fraction * 100).round()}'}), maxLines: 1, style: soft),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MiddleText(doc.name, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: c.dsADeckText, height: 1.3)),
                    const SizedBox(height: 1),
                    Text(page, maxLines: 1, style: soft),
                  ],
                ),
              ),
              const _GoButton(),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: c.deckTrack)),
                    FractionallySizedBox(
                      widthFactor: entry.fraction,
                      alignment: AlignmentDirectional.centerStart,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(3)),
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

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.fresh, required this.onTap});

  final int fresh;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final meta = fresh > 0
        ? (fresh == 1 ? s.t('dsNewFilesOne', {'count': '1'}) : s.t('dsNewFilesMany', {'count': '$fresh'}))
        : s.t('dsNewestFiles');
    return _DeckFront(
      onTap: onTap,
      label: s.t('recentlyAddedTitle'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.deckTextSoft, height: 1.3)),
              ),
              if (fresh > 0)
                Container(
                  height: 18,
                  constraints: const BoxConstraints(minWidth: 18),
                  margin: const EdgeInsetsDirectional.only(start: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(9)),
                  child: Text(
                    fresh > 99 ? '+99' : '+$fresh',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: c.navbarPillText, height: 1.1),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  s.t('recentlyAddedTitle'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500, color: c.dsADeckText, height: 1.3),
                ),
              ),
              const _GoButton(),
            ],
          ),
        ],
      ),
    );
  }
}

/// One line shortened in the middle (android:ellipsize="middle").
class _MiddleText extends StatelessWidget {
  const _MiddleText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        var shown = text;
        if (painter.width > constraints.maxWidth && text.length > 6) {
          final chars = text.characters.toList();
          var keep = chars.length;
          while (keep > 4) {
            keep--;
            final head = (keep + 1) ~/ 2;
            final candidate = '${chars.take(head).join()}…${chars.skip(chars.length - (keep - head)).join()}';
            painter.text = TextSpan(text: candidate, style: style);
            painter.layout();
            if (painter.width <= constraints.maxWidth) {
              shown = candidate;
              break;
            }
          }
        }
        painter.dispose();
        return Text(shown, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: style);
      },
    );
  }
}
