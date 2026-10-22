import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../data/file_library.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart';
import 'file_actions.dart';
import 'files_ui.dart';

/// "All files" / one file type / "Recently added" / search, like the Android FileListActivity:
/// search (with All / PDF / Word / Excel / PPT / TXT / Image tabs when searching every file),
/// select mode (tap the select button or long-press a row; select all; share several files in one
/// share sheet; delete with "Move to recycle bin or delete?"), "Filter by" kept between launches,
/// and pull down to look for new files.
class FileListPage extends StatefulWidget {
  const FileListPage({
    super.key,
    required this.title,
    this.kind,
    this.initialQuery = '',
    this.openSearch = false,
    this.recentlyAdded = false,
  });

  final String title;
  final DocKind? kind;
  final String initialQuery;

  /// The Search screen: opens with the search box and closes with it.
  final bool openSearch;

  /// Files from the last 30 days and newly found ones (new ones first).
  final bool recentlyAdded;

  @override
  State<FileListPage> createState() => _FileListPageState();
}

class _FileListPageState extends State<FileListPage> with SingleTickerProviderStateMixin {
  late final TextEditingController _query = TextEditingController(text: widget.initialQuery);
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _searching = false;

  /// Type chosen in the search tabs (null = All).
  DocKind? _tab;

  static const _tabs = <DocKind?>[null, DocKind.pdf, DocKind.word, DocKind.excel, DocKind.ppt, DocKind.txt, DocKind.image];

  late final TabController _tabController = TabController(length: _tabs.length, vsync: this);

  /// Rows fade in when the list is first filled and after "Filter by".
  final ListAnimGate _anim = ListAnimGate();

  @override
  void initState() {
    super.initState();
    _searching = widget.initialQuery.isNotEmpty || widget.openSearch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = AppScope.of(context).settings;
      settings.markVisitedFileList();
      // the "+N" next to Recently added goes once the list was visited (files keep their "New" tag)
      if (widget.recentlyAdded) settings.markRecentSeen();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // like the Android app, the type tabs also show in Recently added (its category is ALL)
  bool get _showTabs => _searching && widget.kind == null;

  List<DocEntry> _visible(FileLibrary library) {
    final settings = AppScope.of(context).settings;
    final source = widget.recentlyAdded ? library.recentlyAdded : library.active;
    final q = _query.text.trim().toLowerCase();
    final tab = _showTabs ? _tab : null;
    final filtered = source.where((e) {
      // only supported types are listed (the Android app never scans OTHER files)
      if (e.kind == DocKind.other) return false;
      final kindOk = widget.kind == null || e.kind == widget.kind;
      final tabOk = tab == null || e.kind == tab;
      final textOk = !_searching || q.isEmpty || e.name.toLowerCase().contains(q);
      return kindOk && tabOk && textOk;
    }).toList();
    final sorted = sortDocs(filtered, settings.sortField, settings.sortDir);
    if (!widget.recentlyAdded) return sorted;
    // newly found files (not opened yet) first
    return [...sorted.where((e) => e.isNew), ...sorted.where((e) => !e.isNew)];
  }

  void _startSelecting(DocEntry? first) {
    FocusScope.of(context).unfocus();
    setState(() {
      _selecting = true;
      _selected.clear();
      if (first != null) _selected.add(first.id);
    });
  }

  void _stopSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _closeSearch() {
    if (widget.openSearch) {
      Navigator.of(context).maybePop();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = false;
      _tab = null;
      _query.clear();
    });
    _tabController.index = 0;
  }

  bool _refreshing = false;
  final ScrollController _scroll = ScrollController();

  Future<void> _refresh() async {
    final s = S.of(context);
    setState(() => _refreshing = true);
    await AppScope.of(context).library.rescan();
    if (!mounted) return;
    setState(() => _refreshing = false);
    showToast(context, s.t('filesRefreshed'));
  }

  /// The toolbar's refresh button: the same as pulling the list down.
  Future<void> _refreshButton() async {
    await _refreshKey.currentState?.show();
  }

  final GlobalKey<RefreshIndicatorState> _refreshKey = GlobalKey<RefreshIndicatorState>();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final library = AppScope.of(context).library;
    final files = _visible(library);
    final chosen = files.where((e) => _selected.contains(e.id)).toList();
    final allSelected = files.isNotEmpty && chosen.length == files.length;
    final loading = library.phase == LoadPhase.loading;
    if (!loading) _anim.fill(files.isNotEmpty);

    Widget bar;
    if (_selecting) {
      // Selection: back, "N selected", select all
      bar = NativeTopBar(
        titleWidget: Text(
          s.t('selected', {'count': '${chosen.length}'}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c.textPrimary),
        ),
        endPadding: 8,
        onBack: _stopSelecting,
        actions: [
          Opacity(
            opacity: allSelected ? 1 : 0.75,
            child: BarIconButton(
              drawable: ND.icSelectAll,
              tooltip: s.t('selectAll'),
              onTap: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(files.map((e) => e.id));
                }
              }),
            ),
          ),
        ],
      );
    } else if (_searching) {
      // Search: field + Cancel
      bar = NativeSearchBar(
        controller: _query,
        autofocus: widget.openSearch || widget.initialQuery.isEmpty,
        hint: s.t('searchForFiles'),
        cancelLabel: s.t('cancel'),
        onCancel: _closeSearch,
        onChanged: (_) => setState(() {}),
      );
    } else {
      // Normal: back, title, search, refresh, select, filter
      bar = NativeTopBar(
        title: widget.kind == null && !widget.recentlyAdded && !widget.openSearch ? s.t('allFiles') : widget.title,
        actions: [
          BarIconButton(
            drawable: ND.icSearch,
            tooltip: s.t('search'),
            onTap: () => setState(() => _searching = true),
          ),
          BarIconButton(
            drawable: ND.icRefresh,
            onTap: _refreshing ? null : _refreshButton,
          ),
          BarIconButton(
            drawable: ND.icSelect,
            onTap: () {
              if (files.isEmpty) {
                showToast(context, s.t('noFilesFound'));
              } else {
                _startSelecting(null);
              }
            },
          ),
          BarIconButton(
            drawable: ND.icFilter,
            tooltip: s.t('filterBy'),
            onTap: () => _showFilter(context),
          ),
        ],
      );
    }

    return PopScope(
      canPop: !_selecting && !(_searching && !widget.openSearch),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _stopSelecting();
        } else if (_searching) {
          _closeSearch();
        }
      },
      child: Scaffold(
        backgroundColor: c.surface,
        body: SafeArea(
          child: Column(
            children: [
              ColoredBox(color: c.surface, child: bar),
              if (_showTabs)
                NativeTabStrip(
                  controller: _tabController,
                  labels: [for (final kind in _tabs) _tabLabel(s, kind)],
                  onTap: (index) {
                    setState(() => _tab = _tabs[index]);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                  },
                ),
              Expanded(
                child: loading
                    ? const NativeProgress()
                    : RefreshIndicator(
                        key: _refreshKey,
                        color: c.primary,
                        backgroundColor: c.surface,
                        onRefresh: _refresh,
                        child: files.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [NativeEmptyState(text: s.t('noFilesFound'))],
                              )
                            : ListView.builder(
                                controller: _scroll,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 16),
                                itemCount: files.length,
                                itemBuilder: (context, index) {
                                  final entry = files[index];
                                  final selected = _selected.contains(entry.id);
                                  return _anim.wrap(
                                    index,
                                    FileRow(
                                      entry: entry,
                                      selecting: _selecting,
                                      selected: selected,
                                      onTap: () {
                                        if (_selecting) {
                                          setState(() {
                                            selected ? _selected.remove(entry.id) : _selected.add(entry.id);
                                          });
                                        } else {
                                          openEntry(context, entry);
                                        }
                                      },
                                      onLongPress: () {
                                        if (_selecting) {
                                          setState(() => _selected.add(entry.id));
                                        } else {
                                          _startSelecting(entry);
                                        }
                                      },
                                      onBookmark: () => toggleBookmarkWithPill(context, entry),
                                      onMore: () => showFileMenu(context, entry),
                                    ),
                                  );
                                },
                              ),
                      ),
              ),
              if (_selecting)
                NativeSelectBar(
                  enabled: chosen.isNotEmpty,
                  actions: [
                    SelectBarAction(
                      drawable: ND.icShare,
                      label: s.t('share'),
                      onTap: () async {
                        if (chosen.isEmpty) {
                          showToast(context, s.t('selectFilesFirst'));
                          return;
                        }
                        await shareEntries(context, chosen);
                      },
                    ),
                    SelectBarAction(
                      drawable: ND.icDelete,
                      label: s.t('delete'),
                      onTap: () async {
                        if (chosen.isEmpty) {
                          showToast(context, s.t('selectFilesFirst'));
                          return;
                        }
                        final done = await confirmDeleteMany(context, chosen);
                        if (done && mounted) _stopSelecting();
                      },
                    ),
                  ],
                ),
              const BannerSlot(),
            ],
          ),
        ),
      ),
    );
  }

  String _tabLabel(S s, DocKind? kind) {
    return switch (kind) {
      null => s.t('all'),
      DocKind.pdf => s.t('pdf'),
      DocKind.word => s.t('word'),
      DocKind.excel => s.t('excel'),
      DocKind.ppt => s.t('ppt'),
      DocKind.txt => s.t('txt'),
      DocKind.image => s.t('image'),
      DocKind.other => s.t('all'),
    };
  }

  /// "Filter by" (Android sheet_filter): Name / Date / File size + Ascending / Descending,
  /// applied and saved on OK, then the list goes back to the top.
  Future<void> _showFilter(BuildContext context) async {
    final s = S.of(context);
    final settings = AppScope.of(context).settings;
    var field = settings.sortField;
    var dir = settings.sortDir;
    final apply = await showAppSheet<bool>(
      context,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          final c = NC.of(sheetContext);
          // style/FilterRadio: 44dp, half the width, radio_tint button, 15sp text 6dp after it
          Widget option(String label, bool selected, VoidCallback onTap) {
            return Expanded(
              child: InkWell(
                onTap: () => setSheet(onTap),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      NativeRadio(checked: selected),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: c.textPrimary)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.t('filterBy'), style: sheetTitleStyle(sheetContext, size: 17)),
                  const SizedBox(height: 8),
                  Row(children: [
                    option(s.t('sortName'), field == SortField.name, () => field = SortField.name),
                    option(s.t('sortDate'), field == SortField.date, () => field = SortField.date),
                  ]),
                  Row(children: [
                    option(s.t('filterFileSize'), field == SortField.size, () => field = SortField.size),
                    const Spacer(),
                  ]),
                  Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 8), color: c.divider),
                  Row(children: [
                    option(s.t('ascending'), dir == SortDir.asc, () => dir = SortDir.asc),
                    option(s.t('descending'), dir == SortDir.desc, () => dir = SortDir.desc),
                  ]),
                  const SizedBox(height: 18),
                  NativePillButton(label: s.t('ok'), onPressed: () => Navigator.pop(sheetContext, true)),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (apply != true || !mounted) return;
    await settings.setSort(field, dir);
    if (!mounted) return;
    setState(_anim.replay);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }
}
