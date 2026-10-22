import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/format.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../widgets/banner_slot.dart';
import '../../widgets/file_row.dart';
import 'device_files.dart';
import 'file_actions.dart';
import 'files_ui.dart';

/// Folder browser opened from Directories → Storage, like the Android StorageBrowserActivity:
/// "Storage" title with search, a path line ("0 › Download › …"), folders first then files
/// (newest first, hidden ones too), "N files" on folders, files without bookmark / ⋮ (long-press
/// opens the ⋮ menu), back goes up one folder, "This folder is empty".
class StorageBrowserPage extends StatefulWidget {
  const StorageBrowserPage({super.key, required this.root, required this.rootName});

  final String root;
  final String rootName;

  @override
  State<StorageBrowserPage> createState() => _StorageBrowserPageState();
}

class _StorageBrowserPageState extends State<StorageBrowserPage> {
  late String _current = widget.root;
  List<DeviceItem> _items = const [];
  bool _loading = true;
  bool _searching = false;
  int _generation = 0;
  final TextEditingController _query = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final ListAnimGate _anim = ListAnimGate();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(_current);
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _atRoot => p.equals(_current, widget.root);

  Future<void> _load(String dir, {bool animate = true}) async {
    final generation = ++_generation;
    setState(() {
      _current = dir;
      if (animate) _loading = true;
    });
    final items = await listFolder(dir);
    if (!mounted || generation != _generation) return;
    setState(() {
      _items = items;
      _loading = false;
      if (animate) _anim.replay();
    });
    if (animate && _scroll.hasClients) _scroll.jumpTo(0);
  }

  void _up() {
    if (_atRoot) return;
    _load(p.dirname(_current));
  }

  void _closeSearch() {
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = false;
      _query.clear();
    });
  }

  String _pathLine() {
    final relative = p.relative(_current, from: widget.root);
    final parts = relative == '.' ? const <String>[] : p.split(relative);
    return [widget.rootName, ...parts].join('  ›  ');
  }

  String _date(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}/${two(time.day)}/${time.year}';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final q = _query.text.trim().toLowerCase();
    final shown = q.isEmpty ? _items : _items.where((item) => item.name.toLowerCase().contains(q)).toList();
    return PopScope(
      canPop: !_searching && _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searching) {
          _closeSearch();
        } else {
          _up();
        }
      },
      child: Scaffold(
        backgroundColor: c.surface,
        body: SafeArea(
          child: Column(
            children: [
              if (_searching)
                NativeSearchBar(
                  controller: _query,
                  hint: s.t('searchForFiles'),
                  cancelLabel: s.t('cancel'),
                  showClear: false,
                  onCancel: _closeSearch,
                  onChanged: (_) => setState(() {}),
                )
              else
                NativeTopBar(
                  title: s.t('storage'),
                  // back goes up one folder, like the system back
                  onBack: () => Navigator.of(context).maybePop(),
                  actions: [
                    BarIconButton(
                      drawable: ND.icSearch,
                      tooltip: s.t('search'),
                      onTap: () => setState(() => _searching = true),
                    ),
                  ],
                ),
              // the path line: "0  ›  Download  ›  …" on bg_screen, scrolled to its end
              Container(
                height: 36,
                width: double.infinity,
                color: c.bgScreen,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Text(_pathLine(), maxLines: 1, softWrap: false, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const NativeProgress()
                    : shown.isEmpty
                        ? SingleChildScrollView(
                            child: SizedBox(width: double.infinity, child: NativeEmptyState(text: s.t('emptyStorage'))),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.only(bottom: 16),
                            itemCount: shown.length,
                            itemBuilder: (context, index) {
                              final item = shown[index];
                              if (item.isDir) return _anim.wrap(index, _folderRow(context, item));
                              return _anim.wrap(
                                index,
                                FileRow(
                                  entry: deviceEntry(item),
                                  showActions: false,
                                  subtitle: '${_date(item.modified)} · ${formatBytes(item.size)}',
                                  onTap: () async {
                                    await openDevicePath(context, item);
                                    if (mounted) _load(_current, animate: false);
                                  },
                                  onLongPress: () async {
                                    await showDeviceFileMenu(context, item);
                                    if (mounted) _load(_current, animate: false);
                                  },
                                  onBookmark: () {},
                                  onMore: () {},
                                ),
                              );
                            },
                          ),
              ),
              const BannerSlot(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _folderRow(BuildContext context, DeviceItem item) {
    final s = S.of(context);
    final count = item.count == 1 ? s.t('folderFilesOne', {'count': '1'}) : s.t('folderFiles', {'count': '${item.count}'});
    return FolderRow(
      name: item.name,
      meta: count,
      onTap: () {
        if (_searching) _closeSearch();
        _load(item.path);
      },
    );
  }
}
