/// Text search shared by every reader type (PDF, Word, PPT, TXT, Excel).
library;

/// Lower case, non-breaking / special spaces → space, curly quotes → straight quotes,
/// dashes → '-'. One code unit in, one out, so offsets in the folded text are offsets in the
/// original text too.
String foldForSearch(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    out.writeCharCode(_fold(unit));
  }
  return out.toString();
}

/// The query as it is matched: folded, trimmed, inner white space collapsed to one space.
String foldQuery(String query) => foldForSearch(query.trim()).replaceAll(RegExp(r'\s+'), ' ');

int _fold(int c) {
  if (c >= 65 && c <= 90) return c + 32;
  if (c < 128) return c == 9 || c == 10 || c == 13 ? 32 : c;
  switch (c) {
    case 0xA0 || 0x2007 || 0x202F || 0x2009 || 0x200A || 0x2002 || 0x2003 || 0x3000:
      return 32;
    case 0x2018 || 0x2019 || 0x201A || 0x201B || 0x2032:
      return 39;
    case 0x201C || 0x201D || 0x201E || 0x2033:
      return 34;
    case 0x2010 || 0x2011 || 0x2012 || 0x2013 || 0x2014 || 0x2015 || 0x2212:
      return 45;
  }
  if (c >= 0xD800 && c <= 0xDFFF) return c;
  final lower = String.fromCharCode(c).toLowerCase();
  return lower.length == 1 ? lower.codeUnitAt(0) : c;
}

bool _isSpace(int c) => c == 32 || c == 9 || c == 10 || c == 13;

/// Every match of [needle] (from [foldQuery]) in [hay] (from [foldForSearch]) as (start, end).
/// A space in the query matches any run of white space in the text.
List<(int, int)> findMatches(String hay, String needle) {
  final out = <(int, int)>[];
  if (needle.isEmpty || hay.isEmpty) return out;
  final parts = needle.split(' ').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return out;
  var from = 0;
  while (from < hay.length) {
    final start = hay.indexOf(parts.first, from);
    if (start < 0) break;
    var end = start + parts.first.length;
    var ok = true;
    for (var k = 1; k < parts.length; k++) {
      var j = end;
      while (j < hay.length && _isSpace(hay.codeUnitAt(j))) {
        j++;
      }
      if (j == end || !hay.startsWith(parts[k], j)) {
        ok = false;
        break;
      }
      end = j + parts[k].length;
    }
    if (ok) {
      out.add((start, end));
      from = end;
    } else {
      from = start + 1;
    }
  }
  return out;
}

/// One search result.
class SearchHit {
  const SearchHit(this.page, this.item, this.start, this.end);

  /// Page, slide or sheet (0-based).
  final int page;

  /// Text item on the page (Word / TXT / PPT), cell key (Excel: row * 100000 + column),
  /// or -1 when the position on the page is not known (PDF text, text read from pictures).
  final int item;
  final int start;
  final int end;

  int compareTo(SearchHit other) {
    if (page != other.page) return page.compareTo(other.page);
    if (item != other.item) return item.compareTo(other.item);
    return start.compareTo(other.start);
  }
}

/// "…words before match words after…" for results without a position on the page.
(String, String, String) snippetAround(String text, int start, int end, {int context = 36}) {
  final safeStart = start.clamp(0, text.length);
  final safeEnd = end.clamp(safeStart, text.length);
  var from = safeStart - context;
  var to = safeEnd + context;
  if (from < 0) from = 0;
  if (to > text.length) to = text.length;
  final lead = from > 0 ? '…' : '';
  final tail = to < text.length ? '…' : '';
  final before = '$lead${text.substring(from, safeStart).replaceAll(RegExp(r'\s+'), ' ').trimLeft()}';
  final match = text.substring(safeStart, safeEnd).replaceAll(RegExp(r'\s+'), ' ');
  final after = '${text.substring(safeEnd, to).replaceAll(RegExp(r'\s+'), ' ').trimRight()}$tail';
  return (before, match, after);
}
