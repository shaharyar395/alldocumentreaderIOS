import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_scope.dart';
import '../../features/home/create_sheet.dart';
import '../../features/home/home_tab.dart';
import '../../features/settings/settings_tab.dart';
import '../../features/tools/tools_tab.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../services/app_analytics.dart';
import '../../services/ios_analytics.dart';
import '../../services/platform_bridge.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../../widgets/explore_sheet.dart';
import 'rating_sheets.dart';
import 'widget_actions.dart';

/// Registered in MaterialApp.navigatorObservers: the main screen hears when it is back on top
/// (for "Do you think … is helpful?").
final shellRouteObserver = RouteObserver<PageRoute<dynamic>>();

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with RouteAware {
  int _index = 0;
  bool _showCoach = false;

  /// Files are loaded and access is on: the coach mark, then the Discover tip, may show.
  bool _hintsReady = false;
  bool _ready = false;
  bool _exiting = false;
  DateTime? _lastBack;
  PageRoute<dynamic>? _route;

  /// Back on the main screen, like the Android app: closes the coach mark, goes back to the
  /// All files tab, then "Press back again to exit"; a second back within 2 s closes the app.
  /// Sometimes "Thank you for your support!" shows first; closing it closes the app.
  Future<void> _onBack() async {
    final settings = AppScope.of(context).settings;
    if (_showCoach) {
      settings.setFlag('coachSeen', true);
      setState(() => _showCoach = false);
      return;
    }
    if (_index != 0) {
      IosAnalytics.back(_index == 1 ? 'tools' : 'settings');
      setState(() => _index = 0);
      settings.setTab(0);
      return;
    }
    if (_exiting) return;
    final now = DateTime.now();
    final last = _lastBack;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    if (await shouldShowExploreOnExit(context)) {
      if (!mounted) return;
      _exiting = true;
      await showExploreSheet(context);
      _exiting = false;
      SystemNavigator.pop();
      return;
    }
    if (!mounted) return;
    _lastBack = now;
    showToast(context, S.of(context).t('pressBackAgain'));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _route) {
      if (_route != null) shellRouteObserver.unsubscribe(this);
      _route = route;
      shellRouteObserver.subscribe(this, route);
    }
    if (_ready) return;
    _ready = true;
    _index = AppScope.of(context).settings.lastTab.clamp(0, 2);
    IosAnalytics.activate(_shellScreen(_index));
    PlatformBridge.widgetAction.addListener(_onWidgetAction);
    // a widget button that started the app
    WidgetsBinding.instance.addPostFrameCallback((_) => _onWidgetAction());
  }

  @override
  void dispose() {
    IosAnalytics.left(_shellScreen(_index));
    shellRouteObserver.unsubscribe(this);
    PlatformBridge.widgetAction.removeListener(_onWidgetAction);
    super.dispose();
  }

  /// Back on the main screen from another page: sometimes "Do you think … is helpful?".
  @override
  void didPopNext() {
    IosAnalytics.activate(_shellScreen(_index));
    final settings = AppScope.of(context).settings;
    if (!settings.coachSeen || !HelpfulPrompt.shouldShow(settings)) return;
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted || _showCoach || HelpfulPrompt.showing) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      if (HelpfulPrompt.shouldShow(AppScope.of(context).settings)) HelpfulPrompt.show(context);
    });
  }

  /// Home-screen widget buttons (see widget_actions.dart).
  void _onWidgetAction() {
    final action = PlatformBridge.widgetAction.value;
    if (action == null || !mounted) return;
    PlatformBridge.widgetAction.value = null;
    handleWidgetAction(
      context,
      action,
      selectTab: _selectTab,
      openBookmarks: () => homeShowBookmarks.value = true,
    );
  }

  /// Files are loaded and access is on (HomeFragment.maybeShowFirstRunHints): the first time
  /// "Click the folders above to view", then the "Discover new feature" tip.
  void _onHintsReady() {
    if (!mounted) return;
    setState(() => _hintsReady = true);
    final settings = AppScope.of(context).settings;
    if (settings.coachSeen) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (!mounted || _index != 0 || AppScope.of(context).settings.coachSeen) return;
      setState(() => _showCoach = true);
    });
  }

  void _selectTab(int value) {
    if (_index == value) return; // setOnItemReselectedListener: no-op
    IosAnalytics.left(_shellScreen(_index));
    setState(() => _index = value);
    AppScope.of(context).settings.setTab(value);
    IosAnalytics.activate(_shellScreen(value));
  }

  String _shellScreen(int index) => switch (index) {
        1 => 'tools',
        2 => 'settings',
        _ => 'all_files',
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final settings = AppScope.of(context).settings;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: c.bgScreen,
            // activity_main.xml (Android 1.0.75): the page, then the banner under it (AdBar), then
            // the pill tab bar (Files / Tools / Settings + the + create button) under the banner,
            // 16 dp from the sides and 12 dp from the bottom. The bar no longer covers the content.
            // The Discover tip sits with its tail 6 dp above the + (MainActivity.placeDiscoverTip).
            body: Stack(
              children: [
                Column(
                  children: [
                    Expanded(
                      child: IndexedStack(
                        index: _index,
                        children: [HomeTab(onHintsReady: _onHintsReady, visible: _index == 0), const ToolsTab(), const SettingsTab()],
                      ),
                    ),
                    ColoredBox(color: c.bgScreen, child: const BannerSlot()),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: _NavBar(
                          index: _index,
                          labels: [s.t('allFiles'), s.t('tools'), s.t('settings')],
                          icons: const [(ND.icNavFilesOn, ND.icNavFilesOff), (ND.icNavToolsOn, ND.icNavToolsOff), (ND.icNavSettingsOn, ND.icNavSettingsOff)],
                          onSelect: _selectTab,
                          onCreate: () {
                            logEvent('create_open', {'screen': const ['home', 'tools', 'settings'][_index]});
                            showCreateSheet(context);
                          },
                          createLabel: s.t('dsCreateNew'),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_index == 0 && _hintsReady && !_showCoach && settings.coachSeen && !settings.discoverSeen)
                  PositionedDirectional(
                    start: 24,
                    end: 8,
                    // bar: 12 dp margin + 56 dp tall, + button 48 dp centred (4 dp in) → its top is
                    // 64 dp above the safe area; the tail ends 6 dp above it
                    bottom: MediaQuery.paddingOf(context).bottom + 12 + 52 + 6,
                    child: Align(
                      alignment: AlignmentDirectional.bottomEnd,
                      child: _DiscoverTip(
                        onOpen: () {
                          settings.setFlag('discoverSeen', true);
                          createBlankPdf(context);
                        },
                        onClose: () => settings.setFlag('discoverSeen', true),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_showCoach)
            _CoachMark(
              onDone: () async {
                await settings.setFlag('coachSeen', true);
                if (mounted) setState(() => _showCoach = false);
              },
            ),
        ],
      ),
    );
  }
}

/// The floating navigation bar (ds_a_navbar: navbar_bg, 56 dp, 28 dp corners, elevation 8):
/// three tabs where the selected one is twice as wide and carries the navbar_pill with its
/// label (the pill slides and the widths blend, 280 ms), then the 48 dp + (a 44 dp accent circle
/// with ic_add in on_accent) that opens the Create files sheet.
class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.index,
    required this.labels,
    required this.icons,
    required this.onSelect,
    required this.onCreate,
    required this.createLabel,
  });

  final int index;
  final List<String> labels;
  /// (selected, not selected) icon of each tab (ic_nav_*_on / _off).
  final List<(NDrawable, NDrawable)> icons;
  final ValueChanged<int> onSelect;
  final VoidCallback onCreate;
  final String createLabel;

  static const _selectedWeight = 2.0;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Material(
      color: c.navbarBg,
      elevation: 8,
      shadowColor: const Color(0x55000000),
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, end: 2),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: index.toDouble()),
                    duration: still ? Duration.zero : const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    builder: (context, at, _) {
                      // weight of each tab while the selection moves from one tab to another
                      final weights = [
                        for (var i = 0; i < labels.length; i++) 1 + (_selectedWeight - 1) * (1 - (at - i).abs()).clamp(0.0, 1.0),
                      ];
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final total = weights.fold<double>(0, (a, b) => a + b);
                          final unit = constraints.maxWidth / total;
                          final rtl = Directionality.of(context) == TextDirection.rtl;
                          // the pill: where the selected tab is at this blend of widths
                          final lower = at.floor().clamp(0, labels.length - 1);
                          final frac = at - lower;
                          double startOf(int i) => weights.take(i).fold<double>(0, (a, b) => a + b) * unit;
                          final upper = (lower + 1).clamp(0, labels.length - 1);
                          final left = startOf(lower) + (startOf(upper) - startOf(lower)) * frac;
                          final width = weights[lower] * unit + (weights[upper] * unit - weights[lower] * unit) * frac;
                          return Stack(
                            children: [
                              Positioned(
                                left: rtl ? null : left,
                                right: rtl ? left : null,
                                top: 2,
                                bottom: 2,
                                width: width,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(color: c.navbarPill, borderRadius: BorderRadius.circular(22)),
                                ),
                              ),
                              Row(
                                children: [
                                  for (var i = 0; i < labels.length; i++)
                                    Expanded(
                                      flex: (weights[i] * 1000).round(),
                                      child: _NavTab(
                                        label: labels[i],
                                        icon: i == index ? icons[i].$1 : icons[i].$2,
                                        selected: i == index,
                                        showLabel: (at - i).abs() < 0.5,
                                        onTap: () => onSelect(i),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _CreateButton(onTap: onCreate, label: createLabel),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({required this.label, required this.icon, required this.selected, required this.showLabel, required this.onTap});

  final String label;
  final NDrawable icon;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final color = selected ? c.navbarPillText : c.navbarOff;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NativeIcon(icon, size: 22, tint: color),
              if (showLabel)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 6),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.navbarPillText),
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

/// ds_a_nav_add: the 44 dp accent circle (in a 48 dp target) with ic_add; press = scale 0.96.
class _CreateButton extends StatefulWidget {
  const _CreateButton({required this.onTap, required this.label});

  final VoidCallback onTap;
  final String label;

  @override
  State<_CreateButton> createState() => _CreateButtonState();
}

class _CreateButtonState extends State<_CreateButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: Listener(
        onPointerDown: (_) => setState(() => _down = true),
        onPointerCancel: (_) => setState(() => _down = false),
        onPointerUp: (_) => setState(() => _down = false),
        child: AnimatedScale(
          scale: _down ? 0.96 : 1,
          duration: const Duration(milliseconds: 90),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Material(
                color: c.accent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onTap,
                  splashColor: const Color(0x33FFFFFF),
                  child: Padding(padding: const EdgeInsets.all(11), child: NativeIcon(ND.icAdd, tint: c.onAccent)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Discover new feature:" / "Create PDF" (two bold lines, the second blue) with the Create PDF
/// badge, a tail towards the + button and an × (fragment_home.xml tooltip); it pops in (scale
/// 0.6 → 1 with overshoot, 350 ms after 300 ms). Tapping it opens Create PDF, × hides it for good.
class _DiscoverTip extends StatelessWidget {
  const _DiscoverTip({required this.onOpen, required this.onClose});
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final bubble = c.navbarBg; // bg_tooltip
    final body = Padding(
      padding: const EdgeInsetsDirectional.only(top: 9, end: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: onOpen,
            child: Container(
              decoration: NS.bgTooltip(context),
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 18, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle),
                    child: NativeIcon(ND.icCreatePdfBadge, tint: c.navbarPillText),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.t('homeDiscoverNew'), style: TextStyle(color: c.deckTextSoft, fontSize: 12)),
                      const SizedBox(height: 1),
                      Text(s.t('createPdf'), style: TextStyle(fontWeight: FontWeight.w500, color: c.navbarPill, fontSize: 15)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 20),
            child: CustomPaint(size: const Size(16, 10), painter: _TailPainter(bubble)),
          ),
        ],
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 650),
      curve: const Interval(0.46, 1, curve: Curves.easeOutBack),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.6 + 0.4 * t, alignment: AlignmentDirectional.bottomEnd.resolve(Directionality.of(context)), child: child),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          PositionedDirectional(
            top: 0,
            end: 0,
            child: GestureDetector(
              onTap: onClose,
              child: Container(
                width: 24,
                height: 24,
                padding: const EdgeInsets.all(6),
                decoration: NS.bgCircleClose(context),
                child: NativeIcon(ND.icClose, tint: c.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The tooltip's tail (ic_tooltip_tail), in the bubble's colour.
class _TailPainter extends CustomPainter {
  const _TailPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 10);
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(16, 0)
      ..lineTo(10, 9)
      ..quadraticBezierTo(8, 11, 6, 9)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TailPainter oldDelegate) => oldDelegate.color != color;
}

/// First-run coach mark like the Android app (CoachMarkOverlay + layout_coach_mark.xml): the
/// screen dimmed (#8C000000) except a 24 dp rounded spotlight on the category tiles; below it a
/// bouncing hand, "Click the folders above to view" and a 136 x 54 dp OK pill. Fades out (200 ms).
class _CoachMark extends StatefulWidget {
  const _CoachMark({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_CoachMark> createState() => _CoachMarkState();
}

class _CoachMarkState extends State<_CoachMark> with SingleTickerProviderStateMixin {
  Rect? _hole;
  bool _closing = false;
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
    ..repeat(reverse: true);
  late final CurvedAnimation _bounceCurve = CurvedAnimation(parent: _bounce, curve: Curves.easeInOut);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _bounceCurve.dispose();
    _bounce.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) return;
    final target = homeCategoryKey.currentContext?.findRenderObject();
    final me = context.findRenderObject();
    if (target is! RenderBox || me is! RenderBox || !target.hasSize || !target.attached) return;
    final topLeft = target.localToGlobal(Offset.zero, ancestor: me);
    final r = (topLeft & target.size).inflate(6);
    setState(() => _hole = Rect.fromLTRB(r.left < 4 ? 4 : r.left, r.top, r.right > me.size.width - 4 ? me.size.width - 4 : r.right, r.bottom));
  }

  void _dismiss() {
    if (_closing) return;
    setState(() => _closing = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final hole = _hole;
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _closing ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        onEnd: () {
          if (_closing) widget.onDone();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _ScrimPainter(hole))),
              Positioned(
                left: 0,
                right: 0,
                top: hole == null ? null : hole.bottom + 8,
                bottom: hole == null ? 120 : null,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: _bounceCurve,
                        builder: (context, child) => Transform.translate(offset: Offset(0, -12 * _bounceCurve.value), child: child),
                        child: NativeIcon(ND.icHandPointer, width: 56, height: 64),
                      ),
                      const SizedBox(height: 18),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          s.t('coachClickFolders'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.white, fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 136,
                        height: 54,
                        child: FilledButton(
                          onPressed: _dismiss,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.primary,
                            foregroundColor: c.onPrimary,
                            elevation: 0,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
                          ),
                          child: Text(s.t('ok'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
                        ),
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

class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.hole);
  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final spot = hole;
    final paint = Paint()..color = const Color(0x8C000000);
    if (spot == null) {
      canvas.drawPath(full, paint);
      return;
    }
    final cut = Path()..addRRect(RRect.fromRectAndRadius(spot, const Radius.circular(24)));
    canvas.drawPath(Path.combine(PathOperation.difference, full, cut), paint);
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter oldDelegate) => oldDelegate.hole != hole;
}
