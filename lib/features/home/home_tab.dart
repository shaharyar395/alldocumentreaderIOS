import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../data/doc_entry.dart';
import '../../data/file_library.dart';
import '../../features/files/directories_page.dart';
import '../../features/files/file_actions.dart';
import '../../features/files/file_list_page.dart';
import '../../features/files/storage_access.dart';
import '../../features/premium/premium_page.dart';
import '../../features/search/search_page.dart';
import '../../features/shell/main_shell.dart';
import '../../features/shell/rating_sheets.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart';
import '../../widgets/home_art.dart';

/// The category grid on the home screen (the first-run coach mark points at it).
final homeCategoryKey = GlobalKey(debugLabel: 'homeCategories');

/// Recent (false) / Bookmarks (true) on the home screen; the Bookmarks widget button sets it.
final homeShowBookmarks = ValueNotifier<bool>(false);

/// The "All files" tab, like the Android app's HomeFragment / fragment_home.xml.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, this.onHintsReady, this.visible = true});

  /// Called once files are loaded and storage access is on (the coach mark / Discover tip follow).
  final VoidCallback? onHintsReady;

  /// The All files tab is the one on screen (the access dialog only shows then).
  final bool visible;

  @override
  Widget build(BuildContext context) => _HomeBody(onHintsReady: onHintsReady, visible: visible);
}

class _HomeBody extends StatefulWidget {
  const _HomeBody({this.onHintsReady, required this.visible});

  final VoidCallback? onHintsReady;
  final bool visible;

  @override
  State<_HomeBody> createState() => _HomeBodyState();
}

class _HomeBodyState extends State<_HomeBody> with WidgetsBindingObserver, RouteAware {
  /// Storage access (null until checked; always true on iOS).
  bool? _access;
  bool _started = false;
  bool _hintsSent = false;

  /// A category tapped without access: opened once access is given.
  _Tile? _pendingTile;

  /// The open "Allow access to files" dialog, to close it when access comes in.
  BuildContext? _dialogContext;

  /// 0 = Recently added row, 1 = "Loading files…", 2 = "Loaded successfully".
  int _loadStatus = 0;
  PageRoute<dynamic>? _route;
  FileLibrary? _library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    homeShowBookmarks.addListener(_onSegment);
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
    if (_started) return;
    _started = true;
    final library = AppScope.of(context).library;
    _library = library;
    library.addListener(_onLibrary);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onAccessMaybeChanged());
  }

  @override
  void didUpdateWidget(covariant _HomeBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      // the All files tab came on screen (like HomeFragment.onHiddenChanged / onResume)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onAccessMaybeChanged();
        _maybeReloadAfterSave();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    homeShowBookmarks.removeListener(_onSegment);
    shellRouteObserver.unsubscribe(this);
    _library?.removeListener(_onLibrary);
    super.dispose();
  }

  void _onSegment() {
    if (mounted) setState(() {});
  }

  /// The first-run hints wait until files are loaded and access is on (maybeShowFirstRunHints).
  void _onLibrary() {
    final library = _library;
    if (!mounted || _hintsSent || _access != true || library == null) return;
    if (!library.scannedWithAccess) return;
    _hintsSent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onHintsReady?.call();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // back from the system settings page, or files added while the app was in the background
    _onAccessMaybeChanged(resumed: true);
    _maybeReloadAfterSave();
  }

  /// Back on the main screen from another page (HomeFragment.onResume). No access prompt here:
  /// closing the access dialog itself lands here too ("Not now" must not reopen it at once).
  @override
  void didPopNext() {
    _onAccessMaybeChanged(resumed: true, prompt: false);
    _maybeReloadAfterSave();
  }

  /// Like HomeFragment.onAccessMaybeChanged: with access the dialog closes, the access view
  /// goes, the scan starts and the category tapped before opens. Without access no phone files
  /// are listed and the "Allow access to files" dialog shows again each time the All files tab
  /// opens, the app comes back from the background or from the settings page ([prompt]).
  Future<void> _onAccessMaybeChanged({bool resumed = false, bool prompt = true}) async {
    final access = await hasStorageAccess();
    if (!mounted) return;
    final scope = AppScope.of(context);
    final library = scope.library;
    if (_access != access) setState(() => _access = access);
    if (access) {
      _closeDialog();
      library.startWatching();
      if (!library.scannedWithAccess) {
        unawaited(library.rescan());
      } else if (resumed) {
        unawaited(library.refreshIfStale());
      }
      _onLibrary();
      final pending = _pendingTile;
      _pendingTile = null;
      if (pending != null && widget.visible) await _openCategory(pending);
      return;
    }
    // without access only the app's own saved files are listed (phone files found before are
    // hidden by the scan until access is given again)
    if (!library.scanning && (!library.deviceScanned || library.scannedWithAccess)) unawaited(library.rescan());
    if (!prompt || !widget.visible) return;
    // not over another page or a dialog of ours, and not while a full-screen ad is closing
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (scope.ads.fullScreenActive) return;
    if (!scope.settings.permissionPrompted) await scope.settings.markPermissionPrompted();
    if (mounted) await _showAccessDialog();
  }

  Future<void> _showAccessDialog() async {
    if (_dialogContext != null) return;
    final allow = await showStorageAccessDialog(context, onContext: (dialogContext) => _dialogContext = dialogContext);
    // the dialog is closed now (Allow, Not now, back or outside tap): it may be shown again later
    _dialogContext = null;
    if (!mounted) return;
    if (!allow) {
      _pendingTile = null;
      return;
    }
    await requestStorageAccess(context: context);
    // Android 10 and older answer in a system dialog: check again now. No new prompt from here
    // (on 11+ the settings page is open now); coming back to the app asks again if still denied.
    if (mounted) await _onAccessMaybeChanged(prompt: false);
  }

  void _closeDialog() {
    final dialogContext = _dialogContext;
    _dialogContext = null;
    if (dialogContext != null && dialogContext.mounted) Navigator.of(dialogContext).pop(false);
  }

  /// Something was saved elsewhere in the app: "Loading files…" → "Loaded successfully".
  Future<void> _maybeReloadAfterSave() async {
    if (!mounted || !widget.visible || _access != true) return;
    final library = AppScope.of(context).library;
    if (!library.takePendingReload()) return;
    setState(() => _loadStatus = 1);
    await library.rescan();
    if (!mounted) return;
    setState(() => _loadStatus = 2);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted && _loadStatus == 2) setState(() => _loadStatus = 0);
  }

  /// The 5-star sheet once, after coming back from a file list (not together with "helpful?").
  Future<void> _maybeRate() async {
    final settings = AppScope.of(context).settings;
    if (!settings.visitedFileList || settings.rateShown || !settings.coachSeen) return;
    if (HelpfulPrompt.showing || HelpfulPrompt.shouldShow(settings)) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted || settings.rateShown || HelpfulPrompt.showing) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    await showRateSheet(context);
  }

  /// A tile without access: the dialog, and the category opens once access is given.
  Future<void> _onTileTap(_Tile tile) async {
    if (!await hasStorageAccess()) {
      if (!mounted) return;
      _pendingTile = tile;
      await _showAccessDialog();
      return;
    }
    if (mounted) await _openCategory(tile);
  }

  /// Like Android Ads.beforeCategory: full-screen ad → the list → "Get Premium" on top (once per
  /// app run, only when an ad was really shown).
  Future<void> _openCategory(_Tile tile) async {
    final scope = AppScope.of(context);
    final title = tile.kind == null && !tile.directories ? S.of(context).t('homeAllFilesTitle') : tile.label;
    final shown = await scope.ads.showInterstitial(untilClosed: true);
    if (!mounted) return;
    final Widget page = tile.directories ? const DirectoriesPage() : FileListPage(title: title, kind: tile.kind);
    final done = Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    if (shown && !scope.ads.premiumOfferedThisRun && !scope.settings.premium) {
      scope.ads.premiumOfferedThisRun = true;
      unawaited(Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PremiumPage())));
    }
    await done;
    if (mounted) await _maybeRate();
  }

  Future<void> _openRecentlyAdded() async {
    if (!await hasStorageAccess()) {
      if (mounted) await _showAccessDialog();
      return;
    }
    if (!mounted) return;
    final title = S.of(context).t('recentlyAddedTitle');
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FileListPage(title: title, recentlyAdded: true)));
    if (mounted) await _maybeRate();
  }

  /// Pull to refresh: nothing without access; otherwise a new scan and "Files updated".
  Future<void> _refresh() async {
    final s = S.of(context);
    final library = AppScope.of(context).library;
    if (!await hasStorageAccess()) return;
    await library.rescan();
    if (!mounted) return;
    showToast(context, s.t('filesRefreshed'));
  }

  String _filesText(S s, int n) => n == 1 ? s.t('homeFilesOne', {'count': '1'}) : s.t('homeFilesMany', {'count': '$n'});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final library = AppScope.of(context).library;
    final settings = AppScope.of(context).settings;
    final bookmarks = homeShowBookmarks.value;
    final known = _access != null;
    final access = _access ?? false;
    final files = bookmarks ? library.bookmarks : library.recentOpened;
    final fresh = access ? library.newSince(settings.recentSeenAt) : 0;
    final loaded = access && library.scannedWithAccess;
    final firstLoad = access && !library.scannedWithAccess;
    String? count(DocKind? kind) => loaded ? _filesText(s, library.countOf(kind)) : null;
    final total = library.storageTotal;
    final storage = total == null
        ? (loaded ? formatBytes(library.libraryBytes) : null)
        : s.t('homeStorageUsage', {
            'used': formatBytes(total - (library.storageFree ?? 0)),
            'total': formatBytes(total),
          });
    final tiles = [
      _Tile(s.t('all'), count(null), ND.icCatAll, null),
      _Tile(s.t('pdf'), count(DocKind.pdf), ND.icCatPdf, DocKind.pdf),
      _Tile(s.t('word'), count(DocKind.word), ND.icCatWord, DocKind.word),
      _Tile(s.t('excel'), count(DocKind.excel), ND.icCatExcel, DocKind.excel),
      _Tile(s.t('ppt'), count(DocKind.ppt), ND.icCatPpt, DocKind.ppt),
      _Tile(s.t('txt'), count(DocKind.txt), ND.icCatTxt, DocKind.txt),
      _Tile(s.t('image'), count(DocKind.image), ND.icCatImage, DocKind.image),
      _Tile(s.t('directories'), storage, ND.icCatDir, null, directories: true),
    ];

    // the list part under the tabs (rvFiles / emptyView / loadingView / permissionView)
    final Widget listArea;
    if (!known) {
      listArea = ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: const []);
    } else if (!access) {
      listArea = ListView(
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [_AccessMissing(onGrant: _showAccessDialog)],
      );
    } else if (firstLoad) {
      listArea = ListView(
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [_FirstLoad(label: s.t('homeLoadingFiles'))],
      );
    } else if (files.isEmpty) {
      listArea = ListView(
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [_EmptyList(label: s.t('homeEmpty'))],
      );
    } else {
      listArea = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: files.length,
        itemBuilder: (context, index) {
          final entry = files[index];
          return FileRow(
            entry: entry,
            openedAt: entry.openedAt,
            onTap: () => openEntry(context, entry),
            onBookmark: () => toggleBookmarkWithPill(context, entry),
            onMore: () => showFileMenu(context, entry),
          );
        },
      );
    }

    // fragment_home.xml: a fixed header (status bar in bg_header_top, then the bg_home_header
    // gradient with the title row, Recently added and the category grid), a 6 dp divider band,
    // the Recent / Bookmarks tabs and the pull-to-refresh list below them.
    return ColoredBox(
      color: c.surface,
      child: Column(
        children: [
          ColoredBox(
            color: c.bgHeaderTop,
            child: SafeArea(
              bottom: false,
              child: DecoratedBox(
                decoration: NS.bgHomeHeader(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 56,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'All Document Reader',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.textPrimary),
                              ),
                            ),
                            // the crown is for buying Premium: hidden once Premium is on
                            if (!settings.premium)
                              _HeaderButton(
                                onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PremiumPage())),
                                child: NativeIcon(ND.icCrown, size: 24),
                              ),
                            _HeaderButton(
                              onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SearchPage())),
                              child: NativeIcon(ND.icSearch, size: 24, tint: c.textPrimary),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: _loadStatus == 0
                          ? _RecentlyAddedRow(label: s.t('recentlyAddedTitle'), fresh: fresh, onTap: _openRecentlyAdded)
                          : _LoadStatusRow(
                              done: _loadStatus == 2,
                              label: _loadStatus == 2 ? s.t('homeLoadedOk') : s.t('homeLoadingFiles'),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                      child: Column(
                        key: homeCategoryKey,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var row = 0; row < 2; row++)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var col = 0; col < 4; col++)
                                  Expanded(
                                    child: _CategoryCard(
                                      tile: tiles[row * 4 + col],
                                      loading: firstLoad,
                                      onTap: () => _onTileTap(tiles[row * 4 + col]),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Container(height: 6, color: c.divider),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: SizedBox(
                height: 48,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _tab(s.t('recent'), !bookmarks, () => homeShowBookmarks.value = false),
                    _tab(s.t('bookmarks'), bookmarks, () => homeShowBookmarks.value = true),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              color: c.primary,
              backgroundColor: c.surface,
              child: listArea,
            ),
          ),
        ],
      ),
    );
  }

  /// A tab of the TabLayout in fragment_home.xml: 15 sp bold text (primary when selected,
  /// text_secondary otherwise), 10 dp side padding, a centred 24 x 3 dp tab_indicator, no ripple.
  Widget _tab(String label, bool selected, VoidCallback onTap) {
    final c = NC.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: selected ? c.primary : c.textSecondary),
            ),
            Positioned(
              bottom: 0,
              child: AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(width: 24, height: 3, decoration: NS.tabIndicator(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 44 x 44 dp borderless-ripple icon button of the header (btnPremium / btnSearch, 10 dp padding).
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Padding(padding: const EdgeInsets.all(10), child: child),
        ),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.label, this.count, this.icon, this.kind, {this.directories = false});
  final String label;

  /// "N files" / "used/total"; null = no count (no access yet, or still loading).
  final String? count;

  /// ic_cat_* of the Android app's Category enum.
  final NDrawable icon;
  final DocKind? kind;
  final bool directories;
}

/// "Recently added" with the red "+N" of new files, above the category grid (rowRecentlyAdded:
/// 36 dp, bg_recent_row, ic_clock_badge, 14 sp bold, bg_badge_red, ic_chevron_right).
class _RecentlyAddedRow extends StatelessWidget {
  const _RecentlyAddedRow({required this.label, required this.fresh, required this.onTap});

  final String label;
  final int fresh;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Material(
      color: c.recentRowBg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        splashColor: c.rowPressed,
        onTap: onTap,
        child: SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 10, end: 8),
            child: Row(
              children: [
                NativeIcon(ND.icClockBadge, size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary),
                  ),
                ),
                if (fresh > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    height: 16,
                    constraints: const BoxConstraints(minWidth: 16),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: NS.bgBadgeRed(context),
                    child: Text(
                      fresh > 99 ? '+99' : '+$fresh',
                      style: TextStyle(color: c.white, fontSize: 10, fontWeight: FontWeight.w700, height: 1.1),
                    ),
                  ),
                ],
                const Spacer(),
                NativeIcon(ND.icChevronRight, size: 18, tint: c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Loading files…" (spinner) / "Loaded successfully" (ic_loaded_ok) after a file was saved
/// (rowLoadStatus).
class _LoadStatusRow extends StatelessWidget {
  const _LoadStatusRow({required this.done, required this.label});

  final bool done;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsetsDirectional.only(start: 10, end: 8),
      decoration: NS.bgRecentRow(context),
      child: Row(
        children: [
          if (done)
            NativeIcon(ND.icLoadedOk, size: 18)
          else
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.primary)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: c.textPrimary)),
          ),
        ],
      ),
    );
  }
}

/// Access missing: the empty-state picture, the hint and "Grant access" (permissionView).
class _AccessMissing extends StatelessWidget {
  const _AccessMissing({required this.onGrant});

  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
      child: Column(
        children: [
          const EmptyArt(),
          Text(s.t('permissionNeededHint'), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.textSecondary)),
          const SizedBox(height: 14),
          SizedBox(
            height: 44,
            child: FilledButton(
              onPressed: onGrant,
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                foregroundColor: c.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(horizontal: 28),
              ),
              child: Text(s.t('grantAccess'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The first scan: a drifting paper plane and "Loading files…" (loadingView).
class _FirstLoad extends StatelessWidget {
  const _FirstLoad({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        children: [
          const PaperPlaneLoader(),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.textPrimary)),
        ],
      ),
    );
  }
}

/// Nothing in Recent / Bookmarks: the picture and "Empty" (emptyView).
class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          const EmptyArt(),
          Text(label, style: TextStyle(fontSize: 14, color: c.textSecondary)),
        ],
      ),
    );
  }
}

/// One category of the grid (item_category.xml): no card, a borderless ripple, the 38 dp
/// ic_cat_* icon, the 15 sp bold label 6 dp below and a 16 dp line with the count (11.5 sp
/// text_secondary) or a 10 dp text_hint spinner while loading; 8 dp padding top and bottom.
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.tile, required this.loading, required this.onTap});
  final _Tile tile;

  /// First scan running: a small spinner where the count goes.
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final count = tile.count;
    return Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: onTap,
        containedInkWell: false,
        highlightShape: BoxShape.circle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NativeIcon(tile.icon, size: 38),
              const SizedBox(height: 6),
              Text(
                tile.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary),
              ),
              SizedBox(
                height: 16,
                child: Center(
                  child: count != null
                      ? Text(
                          count,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                        )
                      : loading
                          ? SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textHint))
                          : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
