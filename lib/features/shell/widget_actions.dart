import 'package:flutter/material.dart';

import '../../data/doc_entry.dart';
import '../../l10n/s.dart';
import '../editor/editor_flow.dart';
import '../files/file_list_page.dart';
import '../home/home_tab.dart';
import '../search/search_page.dart';

/// Home-screen widget buttons (Android WidgetProviders.kt, iOS `alldocreader://widget/<action>`),
/// like the Android app's widget/Widgets.kt: every button opens the app on the All files tab and
/// then, on top of it:
///  - "search"    the Search screen
///  - "home"      nothing more (the All files tab, Recent list)
///  - "recent"    the Recently added list
///  - "bookmarks" the All files tab with Bookmarks selected
///  - "edit"      "Select a file" (PDF), then the PDF editor
///  - "pdf" / "word" / "excel" / "ppt"   that file type's list
/// [context] must be below the app's Navigator (the main screen's context). [selectTab] switches
/// the bottom tab; [openBookmarks] selects Bookmarks on the All files tab (when null,
/// [homeShowBookmarks] is set directly).
Future<void> handleWidgetAction(
  BuildContext context,
  String action, {
  required void Function(int tab) selectTab,
  void Function()? openBookmarks,
}) async {
  final navigator = Navigator.of(context);
  navigator.popUntil((route) => route.isFirst);
  selectTab(0);
  if (action == 'bookmarks') {
    if (openBookmarks != null) {
      openBookmarks();
    } else {
      homeShowBookmarks.value = true;
    }
    return;
  }
  // the other buttons open the app's home screen with Recent selected
  homeShowBookmarks.value = false;
  final DocKind? kind = switch (action) {
    'pdf' => DocKind.pdf,
    'word' => DocKind.word,
    'excel' => DocKind.excel,
    'ppt' => DocKind.ppt,
    _ => null,
  };
  if (kind != null) {
    await navigator.push(MaterialPageRoute<void>(
      builder: (pageContext) => FileListPage(title: S.of(pageContext).t(kind.name), kind: kind),
    ));
    return;
  }
  if (action == 'search') {
    await navigator.push(MaterialPageRoute<void>(builder: (_) => const SearchPage()));
  } else if (action == 'recent') {
    await navigator.push(MaterialPageRoute<void>(
      builder: (pageContext) => FileListPage(title: S.of(pageContext).t('recentlyAddedTitle'), recentlyAdded: true),
    ));
  } else if (action == 'edit') {
    await openMarkup(context);
  }
  // "home" (and anything unknown): the All files tab is enough
}
