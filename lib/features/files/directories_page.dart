import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart';
import '../search/search_page.dart';
import 'device_files.dart';
import 'file_actions.dart';
import 'files_ui.dart';
import 'storage_access.dart';
import 'storage_browser_page.dart';

/// Directories, like the Android DirectoriesActivity: "Directories" with a search button and the
/// tabs Storage (volumes → folder browser), All documents (every file on the device, newest
/// first) and Recycle bin. [binOnly] is Tools → Recycle bin (Android RecycleBinActivity): the bin
/// alone with select mode and Restore / Delete.
class DirectoriesPage extends StatefulWidget {
  const DirectoriesPage({super.key, this.initialTab = 0, this.binOnly = false});

  final int initialTab;
  final bool binOnly;

  @override
  State<DirectoriesPage> createState() => _DirectoriesPageState();
}

class _DirectoriesPageState extends State<DirectoriesPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this, initialIndex: widget.initialTab.clamp(0, 2));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.binOnly) return const _RecycleBinScreen();
    final s = S.of(context);
    final c = NC.of(context);
    // activity_directories.xml: ‹ Directories 🔍, then Storage / All documents / Recycle bin tabs
    return Scaffold(
      backgroundColor: c.surface,
      body: SafeArea(
        child: Column(
          children: [
            NativeTopBar(
              title: s.t('directories'),
              actions: [
                BarIconButton(drawable: ND.icSearch, tooltip: s.t('search'), onTap: () => openSearchPage(context)),
              ],
            ),
            NativeTabStrip(
              controller: _tabs,
              selectedColor: c.textPrimary,
              tabPadding: 12,
              labels: [s.t('storage'), s.t('allDocuments'), s.t('recycleBin')],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: const [_StorageTab(), _AllDocumentsTab(), _BinTab()],
              ),
            ),
            const BannerSlot(),
          ],
        ),
      ),
    );
  }
}

/// fragment_dir_list.xml empty view ("Allow file access to see your documents", "Empty" …).
class _TabMessage extends StatelessWidget {
  const _TabMessage({required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SizedBox(width: double.infinity, child: NativeDirEmptyState(title: title, subtitle: body)),
    );
  }
}

/// Reloads a tab when the app comes back (access granted in system settings, files changed).
mixin _ReloadOnResume<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  void reload();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reload();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) reload();
  }
}

// ------------------------------------------------------------------ Storage

class _StorageTab extends StatefulWidget {
  const _StorageTab();

  @override
  State<_StorageTab> createState() => _StorageTabState();
}

class _StorageTabState extends State<_StorageTab> with WidgetsBindingObserver, _ReloadOnResume<_StorageTab>, AutomaticKeepAliveClientMixin {
  bool? _access;
  List<StorageVolume>? _volumes;
  final ListAnimGate _anim = ListAnimGate();

  @override
  bool get wantKeepAlive => true;

  @override
  Future<void> reload() async {
    final access = await hasStorageAccess();
    if (!mounted) return;
    if (!access) {
      setState(() => _access = false);
      return;
    }
    final volumes = await storageVolumes();
    if (!mounted) return;
    setState(() {
      _access = true;
      _volumes = volumes;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = S.of(context);
    if (_access == false) return _TabMessage(title: s.t('permissionNeededHint'));
    final volumes = _volumes;
    if (volumes == null) return const NativeProgress();
    if (volumes.isEmpty) return _TabMessage(title: s.t('dirEmpty'));
    _anim.fill(true);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: volumes.length,
      itemBuilder: (context, index) {
        final volume = volumes[index];
        final count = volume.count == 1 ? s.t('folderFilesOne', {'count': '1'}) : s.t('folderFiles', {'count': '${volume.count}'});
        return _anim.wrap(
          index,
          FolderRow(
            name: volume.name,
            meta: count,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => StorageBrowserPage(root: volume.root, rootName: volume.name)),
              );
              if (mounted) reload();
            },
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ All documents

class _AllDocumentsTab extends StatefulWidget {
  const _AllDocumentsTab();

  @override
  State<_AllDocumentsTab> createState() => _AllDocumentsTabState();
}

class _AllDocumentsTabState extends State<_AllDocumentsTab>
    with WidgetsBindingObserver, _ReloadOnResume<_AllDocumentsTab>, AutomaticKeepAliveClientMixin {
  bool? _access;
  List<(DeviceItem, DocEntry)>? _files;
  int _generation = 0;
  final ListAnimGate _anim = ListAnimGate();

  @override
  bool get wantKeepAlive => true;

  @override
  Future<void> reload() async {
    final generation = ++_generation;
    final access = await hasStorageAccess();
    if (!mounted || generation != _generation) return;
    if (!access) {
      setState(() => _access = false);
      return;
    }
    final volumes = await storageVolumes();
    final items = await allDeviceFiles([for (final v in volumes) v.root]);
    if (!mounted || generation != _generation) return;
    setState(() {
      _access = true;
      _files = [for (final item in items) (item, deviceEntry(item))];
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = S.of(context);
    if (_access == false) return _TabMessage(title: s.t('permissionNeededHint'));
    final files = _files;
    if (files == null) return const NativeProgress();
    if (files.isEmpty) return _TabMessage(title: s.t('dirEmpty'));
    _anim.fill(true);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final (item, entry) = files[index];
        return _anim.wrap(
          index,
          FileRow(
            entry: entry,
            showActions: false,
            onTap: () => openDevicePath(context, item),
            onLongPress: () async {
              await showDeviceFileMenu(context, item);
              if (mounted) reload();
            },
            onBookmark: () {},
            onMore: () {},
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ Recycle bin

/// Restore / Delete permanently for one file of the bin (util/ActionSheet: handle, header with
/// where the file was, ic_restore / ic_delete_forever rows).
Future<String?> _binActionSheet(BuildContext context, DocEntry entry) {
  final s = S.of(context);
  return showAppSheet<String>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NativeSheetHeader(
              icon: FileKindIcon(kind: entry.kind, size: 36),
              title: entry.name,
              subtitle: entry.originalPath,
            ),
            NativeSheetAction(drawable: ND.icRestore, label: s.t('restoreFile'), onTap: () => Navigator.pop(sheet, 'restore')),
            NativeSheetAction(drawable: ND.icDeleteForever, label: s.t('deleteForever'), onTap: () => Navigator.pop(sheet, 'delete')),
          ],
        ),
      ),
    ),
  );
}

/// Directories → Recycle bin (Android RecycleBinFragment): "Files in the recycle bin can be
/// restored within 30 days." + Empty bin, rows "N days left · size", tap or ⋮ for Restore (back
/// to where the file was) / Delete permanently.
class _BinTab extends StatelessWidget {
  const _BinTab();

  Future<void> _restore(BuildContext context, DocEntry entry) async {
    final s = S.of(context);
    var ok = true;
    try {
      await AppScope.of(context).library.restore(entry);
    } catch (_) {
      ok = false;
    }
    if (!context.mounted) return;
    showToast(context, s.t(ok ? 'restored' : 'restoreFailed'));
  }

  Future<void> _deleteForever(BuildContext context, DocEntry entry) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.t('deleteForever')),
        content: Text(entry.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AppScope.of(context).library.deleteForever(entry);
  }

  Future<void> _emptyBin(BuildContext context) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.t('emptyBin')),
        content: Text(s.t('emptyBinConfirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(s.t('delete'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AppScope.of(context).library.emptyBin();
  }

  Future<void> _actions(BuildContext context, DocEntry entry) async {
    final action = await _binActionSheet(context, entry);
    if (!context.mounted || action == null) return;
    if (action == 'restore') {
      await _restore(context, entry);
    } else {
      await _deleteForever(context, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final files = AppScope.of(context).library.recycled;
    if (files.isEmpty) return _TabMessage(title: s.t('dirEmpty'), body: s.t('recycleMessage'));
    return Column(
      children: [
        // binHeader: 44dp bg_screen strip with the 30-day note and a red "Empty bin"
        Container(
          height: 44,
          color: c.bgScreen,
          padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(s.t('recycleMessage'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
              ),
              SizedBox(
                height: 36,
                child: InkWell(
                  onTap: () => _emptyBin(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Center(
                      widthFactor: 1,
                      child: Text(s.t('emptyBin'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c.danger)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 4, bottom: 16),
            itemCount: files.length,
            itemBuilder: (context, index) {
              final entry = files[index];
              return FileRow(
                entry: entry,
                daysLeft: entry.daysLeft(),
                showBookmark: false,
                onTap: () => _actions(context, entry),
                onLongPress: () => _actions(context, entry),
                onBookmark: () {},
                onMore: () => _actions(context, entry),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Tools → Recycle bin (Android RecycleBinActivity): "Files will be permanently deleted 30 days
/// after being moved here.", "N days" per file, the check button starts select mode ("N
/// selected", select all) with Restore / Delete at the bottom.
class _RecycleBinScreen extends StatefulWidget {
  const _RecycleBinScreen();

  @override
  State<_RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<_RecycleBinScreen> {
  bool _selecting = false;
  final Set<String> _selected = {};

  void _stopSelecting() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _restore(List<DocEntry> list) async {
    final s = S.of(context);
    final done = await AppScope.of(context).library.restoreMany(list);
    if (!mounted) return;
    _stopSelecting();
    if (done == 0) {
      showToast(context, s.t('restoreFailed'));
    } else {
      showToast(context, done == 1 ? s.t('restoredCountOne', {'count': '1'}) : s.t('restoredCount', {'count': '$done'}));
    }
  }

  Future<void> _deleteForever(List<DocEntry> list) async {
    final s = S.of(context);
    // sheet_confirm.xml: "Delete permanently", the count message, Cancel / Delete
    final ok = await showNativeConfirmSheet(
      context,
      title: s.t('deleteForever'),
      message: s.t('deleteForeverMessage', {'count': '${list.length}'}),
      okLabel: s.t('delete'),
      cancelLabel: s.t('cancel'),
    );
    if (!ok || !mounted) return;
    await AppScope.of(context).library.deleteManyForever(list);
    if (!mounted) return;
    _stopSelecting();
    showToast(context, s.t('deletedSuccessfully'));
  }

  Future<void> _actions(DocEntry entry) async {
    final action = await _binActionSheet(context, entry);
    if (!mounted || action == null) return;
    if (action == 'restore') {
      await _restore([entry]);
    } else {
      await _deleteForever([entry]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final files = AppScope.of(context).library.recycled;
    if (_selecting && files.isEmpty) {
      _selecting = false;
      _selected.clear();
    }
    final chosen = files.where((e) => _selected.contains(e.id)).toList();
    final allSelected = files.isNotEmpty && chosen.length == files.length;
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stopSelecting();
      },
      child: Scaffold(
        backgroundColor: c.surface,
        body: SafeArea(
          child: Column(
            children: [
              // ‹ Recycle bin / N selected  ·  select mode / select all
              NativeTopBar(
                title: _selecting ? s.t('selected', {'count': '${chosen.length}'}) : s.t('recycleBin'),
                titleSize: 18,
                backPadding: 12,
                onBack: () {
                  if (_selecting) {
                    _stopSelecting();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
                actions: [
                  if (files.isNotEmpty)
                    BarIconButton(
                      drawable: _selecting ? ND.icSelectAll : ND.icSelect,
                      padding: 11,
                      tooltip: _selecting ? s.t('selectAll') : null,
                      onTap: () => setState(() {
                        if (!_selecting) {
                          _selecting = true;
                          _selected.clear();
                        } else if (allSelected) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(files.map((e) => e.id));
                        }
                      }),
                    ),
                ],
              ),
              // (i) Files will be permanently deleted 30 days after being moved here.
              Container(
                width: double.infinity,
                color: c.surfaceVariant,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    NativeIcon(ND.icInfo, size: 18, tint: c.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(s.t('binInfo'), style: TextStyle(fontSize: 12, color: c.textSecondary))),
                  ],
                ),
              ),
              Expanded(
                child: files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const NativeIcon(ND.icRtRecycleBin, size: 96),
                            const SizedBox(height: 12),
                            Text(s.t('binEmpty'), textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.textSecondary)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        itemCount: files.length,
                        itemBuilder: (context, index) {
                          final entry = files[index];
                          final days = entry.daysLeft();
                          final selected = _selected.contains(entry.id);
                          return FileRow(
                            entry: entry,
                            daysLeft: days,
                            subtitle: days == 1 ? s.t('binDaysOne', {'days': '1'}) : s.t('binDays', {'days': '$days'}),
                            // like the native screen: no bookmark / ⋮ (tap opens Restore / Delete)
                            showActions: false,
                            selecting: _selecting,
                            selected: selected,
                            onTap: () {
                              if (_selecting) {
                                setState(() => selected ? _selected.remove(entry.id) : _selected.add(entry.id));
                              } else {
                                _actions(entry);
                              }
                            },
                            onLongPress: () {
                              if (_selecting) {
                                setState(() => _selected.add(entry.id));
                              } else {
                                setState(() {
                                  _selecting = true;
                                  _selected
                                    ..clear()
                                    ..add(entry.id);
                                });
                              }
                            },
                            onBookmark: () {},
                            onMore: () => _actions(entry),
                          );
                        },
                      ),
              ),
              // Restore · Delete (selection mode)
              if (_selecting)
                NativeSelectBar(
                  enabled: chosen.isNotEmpty,
                  labelSize: 11,
                  labelGap: 2,
                  actions: [
                    SelectBarAction(
                      drawable: ND.icRestore,
                      label: s.t('restore'),
                      onTap: () => chosen.isEmpty ? showToast(context, s.t('selectFilesFirst')) : _restore(chosen),
                    ),
                    SelectBarAction(
                      drawable: ND.icDelete,
                      label: s.t('delete'),
                      onTap: () => chosen.isEmpty ? showToast(context, s.t('selectFilesFirst')) : _deleteForever(chosen),
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
}
