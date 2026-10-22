import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/doc_entry.dart';
import '../../data/file_library.dart';
import '../../l10n/s.dart';
import '../../native/native_colors.dart';
import '../../native/native_drawables.dart';
import '../../native/native_icon.dart';
import '../../native/native_shapes.dart';
import '../../widgets/file_row.dart';
import '../files/file_actions.dart';
import '../files/files_ui.dart';

/// The search screen, like the Android SearchActivity: back, a search field with a clear
/// button, and the matching files — nothing until something is typed, documents first and
/// pictures after, newest first. No type tabs, select or filter.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<DocEntry> _results(FileLibrary library) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final list = library.active.where((e) => e.kind != DocKind.other && e.name.toLowerCase().contains(q)).toList();
    list.sort((a, b) {
      final ai = a.kind == DocKind.image;
      final bi = b.kind == DocKind.image;
      if (ai != bi) return ai ? 1 : -1;
      return b.modified.compareTo(a.modified);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = NC.of(context);
    final library = AppScope.of(context).library;
    final query = _query.text.trim();
    final results = _results(library);
    Widget body;
    if (query.isEmpty) {
      body = const SizedBox.shrink();
    } else if (library.phase == LoadPhase.loading) {
      body = Align(alignment: Alignment.topCenter, child: NativeLoadingState(text: s.t('homeLoadingFiles')));
    } else if (results.isEmpty) {
      body = SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: SizedBox(width: double.infinity, child: NativeEmptyState(text: s.t('noFilesFound'))),
      );
    } else {
      body = ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: results.length,
        itemBuilder: (context, index) {
          final entry = results[index];
          return FileRow(
            entry: entry,
            onTap: () => openEntry(context, entry),
            onBookmark: () => toggleBookmarkWithPill(context, entry),
            onMore: () => showFileMenu(context, entry),
          );
        },
      );
    }
    // activity_search.xml: 60dp bar — ‹ (48dp) and a 42dp rounded field with 🔍, hint and ✕
    return Scaffold(
      backgroundColor: c.surface,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 4, end: 12),
                child: Row(
                  children: [
                    RowIconButton(
                      drawable: ND.icBack,
                      size: 48,
                      padding: 12,
                      tint: c.textPrimary,
                      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Container(
                        height: 42,
                        decoration: NS.bgSearchField(context),
                        padding: const EdgeInsetsDirectional.only(start: 14, end: 6),
                        child: Row(
                          children: [
                            NativeIcon(ND.icSearch, size: 18, tint: c.textSecondary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: NativeTextField(
                                controller: _query,
                                focusNode: _focus,
                                hint: s.t('searchHint'),
                                textInputAction: TextInputAction.search,
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            if (_query.text.isNotEmpty)
                              RowIconButton(
                                drawable: ND.icClose,
                                size: 32,
                                padding: 7,
                                tint: c.textSecondary,
                                onTap: () => setState(_query.clear),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Opens the search screen (every search button of the app).
Future<void> openSearchPage(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
}
