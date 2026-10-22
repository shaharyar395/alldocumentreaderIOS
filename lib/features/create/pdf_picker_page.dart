import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../core/format.dart';
import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../widgets/chrome.dart';
import '../../widgets/file_row.dart';
import '../files/files_ui.dart';
import '../files/storage_access.dart';

/// A PDF chosen in "Select a file": one from the app's library ([entry]) or one browsed from
/// another app.
class PdfPick {
  PdfPick({required this.path, required this.name, required this.bytes, this.entry, this.modified});

  final String path;
  final String name;
  final int bytes;
  final DocEntry? entry;
  final DateTime? modified;
  int pages = 0;
}

/// "MM/dd/yyyy" like the Android "Select a file" rows.
String shortDate(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}/${two(time.day)}/${time.year}';
}

/// "Select a file" / "Select PDFs to merge": the PDFs in the app (newest first, search) with a
/// checkbox on every row when [multiple] ("2 selected", "Continue (2)"), plus Browse for files
/// from other apps.
class PdfPickerPage extends StatefulWidget {
  const PdfPickerPage({
    super.key,
    required this.title,
    this.multiple = false,
    this.minimum = 1,
    this.preselected = const [],
    this.kinds = const {DocKind.pdf},
    this.extensions = const ['pdf'],
    this.accept,
    this.rejectMessage,
  });

  final String title;
  final bool multiple;
  final int minimum;
  final List<PdfPick> preselected;

  /// Which files of the library are listed, and which extensions Browse offers.
  final Set<DocKind> kinds;
  final List<String> extensions;

  /// Files this tool can use; tapping another one shows [rejectMessage] and keeps the list open
  /// (e.g. old .doc / .ppt in Word / PPT to PDF).
  final bool Function(String name)? accept;
  final String? rejectMessage;

  @override
  State<PdfPickerPage> createState() => _PdfPickerPageState();
}

class _PdfPickerPageState extends State<PdfPickerPage> {
  final List<PdfPick> _browsed = [];
  final List<String> _selected = [];
  final Map<String, PdfPick> _picks = {};
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  final ListAnimGate _anim = ListAnimGate();

  /// File access (Android): without it the list is empty with "Allow file access …".
  bool _access = true;

  @override
  void initState() {
    super.initState();
    hasStorageAccess().then((value) {
      if (mounted && value != _access) setState(() => _access = value);
    });
    for (final pick in widget.preselected) {
      _selected.add(pick.path);
      _picks[pick.path] = pick;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PdfPick> _items() {
    final library = AppScope.of(context).library;
    final entries = _access
        ? (library.active.where((entry) => widget.kinds.contains(entry.kind)).toList()..sort((a, b) => b.modified.compareTo(a.modified)))
        : <DocEntry>[];
    final items = <PdfPick>[..._browsed];
    for (final pick in widget.preselected) {
      if (pick.entry == null && !_browsed.any((b) => b.path == pick.path)) items.add(pick);
    }
    for (final entry in entries) {
      final path = entry.fullPath;
      items.add(_picks[path] ?? PdfPick(path: path, name: entry.name, bytes: entry.bytes, entry: entry, modified: entry.modified));
    }
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return items;
    return items.where((item) => item.name.toLowerCase().contains(query)).toList();
  }

  void _toggle(PdfPick pick) {
    setState(() {
      _picks[pick.path] = pick;
      if (_selected.contains(pick.path)) {
        _selected.remove(pick.path);
      } else {
        _selected.add(pick.path);
      }
    });
  }

  Future<void> _browse() async {
    final scope = AppScope.of(context);
    scope.guard.arm(scope.settings);
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: widget.extensions, allowMultiple: widget.multiple);
    } catch (_) {
      result = null;
    }
    if (result == null || !mounted) return;
    final added = <PdfPick>[];
    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      var size = file.size;
      DateTime? modified;
      try {
        final stat = File(path).statSync();
        size = stat.size;
        modified = stat.modified;
      } catch (_) {}
      added.add(PdfPick(path: path, name: file.name.isEmpty ? p.basename(path) : file.name, bytes: size, modified: modified));
    }
    if (added.isEmpty) return;
    if (!widget.multiple) {
      _choose(added.first);
      return;
    }
    setState(() {
      for (final pick in added) {
        _browsed.insert(0, pick);
        _picks[pick.path] = pick;
        if (!_selected.contains(pick.path)) _selected.add(pick.path);
      }
    });
  }

  void _choose(PdfPick pick) {
    final accept = widget.accept;
    if (accept != null && !accept(pick.name)) {
      final message = widget.rejectMessage;
      if (message != null) showToast(context, message);
      return;
    }
    Navigator.of(context).pop(<PdfPick>[pick]);
  }

  void _continue() {
    final picks = [for (final path in _selected) _picks[path]].whereType<PdfPick>().toList();
    Navigator.of(context).pop(picks);
  }

  void _closeSearch() {
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = false;
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final items = _items();
    _anim.fill(items.isNotEmpty);
    final count = _selected.length;
    final canContinue = count >= widget.minimum;
    // activity_pick_file.xml: ‹ Select a file 🔍 (+ Browse) / [Search for files…] Cancel
    final Widget bar = _searching
        ? NativeSearchBar(
            controller: _search,
            hint: s.t('searchForFiles'),
            cancelLabel: s.t('cancel'),
            showClear: false,
            cancelBold: false,
            cancelHeight: 44,
            onCancel: _closeSearch,
            onChanged: (_) => setState(() {}),
          )
        : NativeTopBar(
            title: widget.multiple && count > 0 ? s.t('selected', {'count': '$count'}) : widget.title,
            titleSize: 18,
            actions: [
              BarIconButton(drawable: ND.icSearch, tooltip: s.t('search'), onTap: () => setState(() => _searching = true)),
              NativeTextAction(label: s.t('browse'), color: c.primary, height: 44, onTap: _browse),
            ],
          );
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: Scaffold(
        backgroundColor: c.surface,
        body: SafeArea(
          child: Column(
            children: [
              bar,
              Expanded(
                child: items.isEmpty
                    ? SingleChildScrollView(
                        child: SizedBox(
                          width: double.infinity,
                          child: Column(
                            children: [
                              NativeEmptyState(text: _access ? s.t('noFilesFound') : s.t('permissionNeededHint')),
                              const SizedBox(height: 16),
                              OutlinedButton(onPressed: _browse, child: Text(s.t('browse'))),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final modified = item.modified;
                          final date = modified == null ? '' : '${shortDate(modified)} · ';
                          return _anim.wrap(
                            index,
                            _PickRow(
                              kind: kindForName(item.name),
                              name: item.name,
                              meta: '$date${formatBytes(item.bytes)}',
                              multiple: widget.multiple,
                              checked: _selected.contains(item.path),
                              onTap: () {
                                if (widget.multiple) {
                                  _toggle(item);
                                } else {
                                  _choose(item);
                                }
                              },
                            ),
                          );
                        },
                      ),
              ),
              // Merge PDF: "Continue (n)" — 56dp primary, 28dp corners, dimmed until enough are ticked
              if (widget.multiple)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: Opacity(
                    opacity: canContinue ? 1 : 0.4,
                    child: SizedBox(
                      height: 56,
                      width: double.infinity,
                      child: Material(
                        color: c.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: canContinue ? _continue : null,
                          child: Center(
                            child: Text(
                              count == 0 ? s.t('continueAction') : s.t('continueN', {'count': '$count'}),
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.white),
                            ),
                          ),
                        ),
                      ),
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

/// item_pick_file.xml: 64dp, 32dp type icon, 15sp bold name, "MM/dd/yyyy · size", and a
/// checkbox on every row when several files are picked.
class _PickRow extends StatelessWidget {
  const _PickRow({
    required this.kind,
    required this.name,
    required this.meta,
    required this.multiple,
    required this.checked,
    required this.onTap,
  });

  final DocKind kind;
  final String name;
  final String meta;
  final bool multiple;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = NC.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                FileKindIcon(kind: kind, size: 32),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c.textPrimary)),
                      const SizedBox(height: 3),
                      Text(meta, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: c.textSecondary)),
                    ],
                  ),
                ),
                if (multiple) ...[
                  const SizedBox(width: 8),
                  NativeCheckBox(checked: checked),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens "Select a file" for one file of [kinds] (PDF by default).
Future<PdfPick?> pickOnePdf(
  BuildContext context, {
  String? title,
  Set<DocKind> kinds = const {DocKind.pdf},
  List<String> extensions = const ['pdf'],
  bool Function(String name)? accept,
  String? rejectMessage,
}) async {
  final s = S.of(context);
  final result = await Navigator.of(context).push<List<PdfPick>>(
    MaterialPageRoute(
      builder: (_) => PdfPickerPage(
        title: title ?? s.t('selectAFile'),
        kinds: kinds,
        extensions: extensions,
        accept: accept,
        rejectMessage: rejectMessage,
      ),
    ),
  );
  if (result == null || result.isEmpty) return null;
  return result.first;
}
