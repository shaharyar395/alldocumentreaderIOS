import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../data/doc_entry.dart';
import '../../data/file_library.dart';
import '../../features/files/directories_page.dart';
import '../../features/files/file_actions.dart';
import '../../features/files/file_list_page.dart';
import '../../features/files/storage_access.dart';
import '../../features/home/home_deck.dart';
import '../../features/premium/premium_page.dart';
import '../../features/search/search_page.dart';
import '../../features/shell/main_shell.dart';
import '../../features/shell/rating_sheets.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../services/app_analytics.dart';
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
  /// Storage access (null until checked). Android: "All files access" / the storage permission;
  /// iOS: at least one folder picked in Files. iOS works without it ([_usable]).
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
  /// The collapsing home header + list (HomeScroll.kt): used to stop a leftover fling on touch.
  final GlobalKey<NestedScrollViewState> _nested = GlobalKey<NestedScrollViewState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    homeShowBookmarks.addListener(_onSegment);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_stopFling);
  }

  /// A leftover fling must not eat the next tap. Stopping it here happens before the list sees
  /// that pointer. hold()+cancel was stealing the same pointer on iOS, so tabs and the next
  /// screen never received the tap. jumpTo only runs for a real ballistic fling, and only while
  /// this tab is the one on screen.
  void _stopFling(PointerEvent event) {
    if (event is! PointerDownEvent || !widget.visible) return;
    final nested = _nested.currentState;
    if (nested == null) return;
    for (final controller in [nested.outerController, nested.innerController]) {
      for (final position in controller.positions) {
        // A new finger down while the list is still moving is a leftover fling, not a drag.
        if (!position.isScrollingNotifier.value) continue;
        try {
          position.jumpTo(position.pixels);
        } catch (_) {}
      }
    }
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
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_stopFling);
    WidgetsBinding.instance.removeObserver(this);
    homeShowBookmarks.removeListener(_onSegment);
    shellRouteObserver.unsubscribe(this);
    _library?.removeListener(_onLibrary);
    super.dispose();
  }

  /// Lists, tiles and counts work: Android only with access; iOS always (without a picked folder
  /// the app's own files in Documents are listed).
  bool get _usable => _access == true || (Platform.isIOS && _access != null);

  void _onSegment() {
    if (mounted) setState(() {});
  }

  /// The first-run hints wait until files are loaded and access is on (maybeShowFirstRunHints).
  void _onLibrary() {
    final library = _library;
    if (!mounted || _hintsSent || !_usable || library == null) return;
    if (_access == true) {
      if (!library.scannedWithAccess) return;
    } else {
      // iOS without a picked folder: after the first scan, and not under the one-time access dialog
      if (!library.deviceScanned || _dialogContext != null) return;
      if (!AppScope.of(context).settings.permissionPrompted) return;
    }
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
  /// iOS without a picked folder: the app's own files are listed and the dialog (Files folder
  /// picker) shows only once (settings.permissionPrompted); afterwards the "Grant access" view and
  /// Directories → Storage → "Add folder" remain.
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
    if (!library.scanning && (!library.deviceScanned || library.scannedWithAccess)) {
      unawaited(library.rescan());
    } else if (Platform.isIOS && resumed) {
      // files may have been put into the app's Documents folder from the Files app
      unawaited(library.refreshIfStale());
    }
    _onLibrary();
    if (!prompt || !widget.visible) return;
    if (Platform.isIOS && scope.settings.permissionPrompted) return;
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
      _onLibrary();
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
    if (!mounted || !widget.visible || !_usable) return;
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

  /// A tile without access (Android): the dialog, and the category opens once access is given.
  Future<void> _onTileTap(_Tile tile) async {
    final type = tile.directories ? 'directories' : (tile.kind?.name ?? 'all');
    logEvent('file_type_tap', {'file_type': type});
    logEvent(type == 'all' ? 'all_files_format_tapped' : '${type}_type_format_tapped');
    if (await needsAccessGate()) {
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
    final shown = await scope.ads.showInterstitial(force: true, untilClosed: true, honorCooldown: true);
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
    if (await needsAccessGate()) {
      if (mounted) await _showAccessDialog();
      return;
    }
    if (!mounted) return;
    final title = S.of(context).t('recentlyAddedTitle');
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FileListPage(title: title, recentlyAdded: true)));
    if (mounted) await _maybeRate();
  }

  /// Pull to refresh: nothing without access (Android); otherwise a new scan and "Files updated".
  Future<void> _refresh() async {
    final s = S.of(context);
    final library = AppScope.of(context).library;
    if (await needsAccessGate()) return;
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
    final usable = _usable;
    final files = bookmarks ? library.bookmarks : library.recentOpened;
    final fresh = usable ? library.newSince(settings.recentSeenAt) : 0;
    // iOS without a picked folder: the app's own files, counted once the first scan is done
    final scanned = access ? library.scannedWithAccess : library.deviceScanned;
    final loaded = usable && scanned;
    final firstLoad = usable && !scanned;
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
    } else if (!usable || (!access && !firstLoad && files.isEmpty)) {
      // Android without access; iOS without a picked folder and nothing in Recent / Bookmarks yet
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
      listArea = NotificationListener<ScrollStartNotification>(
        // scrolling closes an open swipe layer (FileSwipeHelper.onScrollStateChanged)
        onNotification: (_) {
          FileRow.openRow.value = null;
          return false;
        },
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 2, bottom: kNavBarClearance),
          itemCount: files.length,
          itemBuilder: (context, index) {
            final entry = files[index];
            return FileRow(
              key: ValueKey(entry.id),
              entry: entry,
              openedAt: entry.openedAt,
              onTap: () => openEntry(context, entry, source: 'home'),
              onBookmark: () => toggleBookmarkWithPill(context, entry),
              onMore: () => showFileMenu(context, entry),
              onDelete: () => confirmDelete(context, entry),
            );
          },
        ),
      );
    }

    // fragment_home.xml ("Plum deck" 1.0.35+): on the page colour, a header that scrolls away
    // (title bar, the card deck, its dots, the load-status pill and the type circles), the
    // Recent / Bookmarks text tabs that stay, and the pull-to-refresh list of file cards.
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('All Document Reader', maxLines: 1, overflow: TextOverflow.ellipsis, style: dsScreenTitle(context)),
                ),
                DsTopAction(
                  icon: ND.icCrown,
                  keepColors: true,
                  iconPadding: 13,
                  tooltip: s.t('getPremium'),
                  onTap: () {
                    logEvent('all_files_premium_tapped');
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PremiumPage()));
                  },
                ),
                const SizedBox(width: 2),
                DsTopAction(
                  icon: ND.icSearch,
                  tooltip: s.t('search'),
                  onTap: () {
                    logEvent('all_files_search_tapped');
                    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SearchPage()));
                  },
                ),
              ],
            ),
          ),
        ),
        HomeDeck(fresh: fresh, onRecentlyAdded: _openRecentlyAdded),
        if (_loadStatus != 0)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _LoadStatusRow(
                done: _loadStatus == 2,
                label: _loadStatus == 2 ? s.t('homeLoadedOk') : s.t('homeLoadingFiles'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
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
                          index: row * 4 + col,
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
    );
    return ColoredBox(
      color: c.bgScreen,
      child: SafeArea(
        bottom: false,
        child: NestedScrollView(
          key: _nested,
          // fragment_home.xml (1.0.75): the header scrolls away, comes back as soon as the list is
          // pulled the other way and snaps open / closed (scroll|enterAlways|snap)
          floatHeaderSlivers: true,
          headerSliverBuilder: (context, inner) => [
            SliverFloatingHeader(child: header),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabsHeader(
                color: c.bgScreen,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 6),
                    child: DsTextTabs(
                      labels: [s.t('recent'), s.t('bookmarks')],
                      index: bookmarks ? 1 : 0,
                      onSelect: (i) {
                        if ((i == 1) == homeShowBookmarks.value) return;
                        logEvent(i == 0 ? 'recent_btn_clicked' : 'bookmarks_btn_clicked');
                        homeShowBookmarks.value = i == 1;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
          body: RefreshIndicator(
            onRefresh: _refresh,
            color: c.primary,
            backgroundColor: c.surface,
            child: listArea,
          ),
        ),
      ),
    );
  }
}

/// The pinned Recent / Bookmarks row (48 dp) on the page colour.
class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  double get minExtent => 48;

  @override
  double get maxExtent => 48;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => ColoredBox(color: color, child: child);

  @override
  bool shouldRebuild(covariant _TabsHeader oldDelegate) => oldDelegate.color != color || oldDelegate.child != child;
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

/// "Loading files…" (spinner) / "Loaded successfully" (ic_loaded_ok) after a file was saved
/// (rowLoadStatus).
class _LoadStatusRow extends StatelessWidget {
  const _LoadStatusRow({required this.done, required this.label});

  final bool done;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    // rowLoadStatus: a 34 dp surface pill (16 dp corners), accent spinner / ic_loaded_ok, 13 sp
    return Container(
      height: 34,
      padding: const EdgeInsetsDirectional.only(start: 12, end: 16),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done)
            NativeIcon(ND.icLoadedOk, size: 18)
          else
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.textPrimary)),
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
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: onGrant,
              style: FilledButton.styleFrom(
                backgroundColor: c.accent,
                foregroundColor: c.onAccent,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(horizontal: 28),
              ),
              child: Text(s.t('grantAccess'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
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
          Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.textPrimary)),
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

/// One type circle (item_category.xml, "Plum deck"): the 44 dp outlined ic_cat_* circle (it pops
/// in once, staggered), the 13 sp medium label 6 dp below and a 16 dp line with the count
/// (11 sp text_secondary) or a 10 dp accent_soft spinner while loading; 8 dp padding top / bottom.
class _CategoryCard extends StatefulWidget {
  const _CategoryCard({required this.tile, required this.index, required this.loading, required this.onTap});
  final _Tile tile;
  final int index;

  /// First scan running: a small spinner where the count goes.
  final bool loading;
  final VoidCallback onTap;

  @override
  State<_CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<_CategoryCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: 40 * widget.index), () {
      if (mounted) _pop.forward();
    });
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    final tile = widget.tile;
    final count = tile.count;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      label: count == null ? tile.label : '${tile.label}, $count',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: widget.onTap,
          containedInkWell: false,
          highlightShape: BoxShape.circle,
          splashColor: c.rowPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (still)
                  NativeIcon(tile.icon, size: 44)
                else
                  ScaleTransition(
                    scale: CurvedAnimation(parent: _pop, curve: Curves.easeOutBack),
                    child: NativeIcon(tile.icon, size: 44),
                  ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    tile.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.textPrimary, height: 1.3),
                  ),
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
                            style: TextStyle(fontSize: 11, color: c.textSecondary),
                          )
                        : widget.loading
                            ? SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.accentSoft))
                            : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
