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
    PlatformBridge.widgetAction.addListener(_onWidgetAction);
    // a widget button that started the app
    WidgetsBinding.instance.addPostFrameCallback((_) => _onWidgetAction());
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    PlatformBridge.widgetAction.removeListener(_onWidgetAction);
    super.dispose();
  }

  /// Back on the main screen from another page: sometimes "Do you think … is helpful?".
  @override
  void didPopNext() {
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
      selectTab: (tab) {
        if (_index == tab) return;
        setState(() => _index = tab);
        AppScope.of(context).settings.setTab(tab);
      },
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
    setState(() => _index = value);
    AppScope.of(context).settings.setTab(value);
  }

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
            body: IndexedStack(
              index: _index,
              children: [HomeTab(onHintsReady: _onHintsReady, visible: _index == 0), const ToolsTab(), const SettingsTab()],
            ),
            // fragment_home.xml: the "Discover new feature" tip 10 dp above the + button, both
            // 18 dp from the end / bottom
            floatingActionButton: _index == 0
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(end: 2, bottom: 2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (_hintsReady && !_showCoach && settings.coachSeen && !settings.discoverSeen) ...[
                          _DiscoverTip(
                            onOpen: () {
                              settings.setFlag('discoverSeen', true);
                              createBlankPdf(context);
                            },
                            onClose: () => settings.setFlag('discoverSeen', true),
                          ),
                          const SizedBox(height: 10),
                        ],
                        FloatingActionButton(
                          onPressed: () => showCreateSheet(context),
                          backgroundColor: c.fabBlue,
                          foregroundColor: c.white,
                          elevation: 6,
                          shape: const CircleBorder(),
                          child: NativeIcon(ND.icAdd, size: 26, tint: c.white),
                        ),
                      ],
                    ),
                  )
                : null,
            // activity_main.xml: the ad bar (surface), a 1 dp divider, then the 60 dp
            // BottomNavigationView (surface, 22 dp icons, 12 sp labels, primary / nav_off)
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BannerSlot(),
                Container(height: 1, color: c.divider),
                ColoredBox(
                  color: c.surface,
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 60,
                      child: Row(
                        children: [
                          _NavItem(
                            label: s.t('allFiles'),
                            on: ND.icNavFilesOn,
                            off: ND.icNavFilesOff,
                            selected: _index == 0,
                            onTap: () => _selectTab(0),
                          ),
                          _NavItem(
                            label: s.t('tools'),
                            on: ND.icNavToolsOn,
                            off: ND.icNavToolsOff,
                            selected: _index == 1,
                            onTap: () => _selectTab(1),
                          ),
                          _NavItem(
                            label: s.t('settings'),
                            on: ND.icNavSettingsOn,
                            off: ND.icNavSettingsOff,
                            selected: _index == 2,
                            onTap: () => _selectTab(2),
                          ),
                        ],
                      ),
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

/// One BottomNavigationView item (labelVisibilityMode="labeled"): the ic_nav_*_on / _off icon
/// tinted by nav_item_color (primary when checked, nav_off otherwise), the 12 sp label below,
/// a row_pressed ripple.
class _NavItem extends StatelessWidget {
  const _NavItem({required this.label, required this.on, required this.off, required this.selected, required this.onTap});

  final String label;
  final NDrawable on;
  final NDrawable off;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final color = selected ? c.primary : c.navOff;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkResponse(
          onTap: onTap,
          containedInkWell: false,
          radius: 40,
          splashColor: c.rowPressed,
          highlightColor: Colors.transparent,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NativeIcon(selected ? on : off, size: 22, tint: color),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color, height: 1.2),
              ),
            ],
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
    final bubble = c.primaryLight; // bg_tooltip
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
                  NativeIcon(ND.icCreatePdfBadge, size: 44),
                  const SizedBox(width: 10),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.t('homeDiscoverNew'), style: TextStyle(fontWeight: FontWeight.w700, color: c.textPrimary, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(s.t('createPdf'), style: TextStyle(fontWeight: FontWeight.w700, color: c.primary, fontSize: 14)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 28),
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
                padding: const EdgeInsets.all(5),
                decoration: NS.bgCircleClose(context),
                child: NativeIcon(ND.icClose, tint: c.white),
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
                          style: TextStyle(color: c.white, fontSize: 16, fontWeight: FontWeight.w700),
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
                            foregroundColor: c.white,
                            elevation: 0,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
                          ),
                          child: Text(s.t('ok'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
