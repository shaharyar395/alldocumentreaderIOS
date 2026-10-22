/// Plain text of an RTF document (formatting, pictures and hidden groups are dropped).
String rtfToText(String rtf) {
  const skipped = {
    'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'object', 'header', 'headerl', 'headerr',
    'headerf', 'footer', 'footerl', 'footerr', 'footerf', 'fldinst', 'themedata', 'colorschememapping',
    'datastore', 'latentstyles', 'listtable', 'listoverridetable', 'rsidtbl', 'generator', 'xmlnstbl',
    'mmathPr', 'filetbl', 'revtbl', 'bkmkstart', 'bkmkend', 'listtext', 'pntext', 'pntxtb', 'pntxta',
  };
  final out = StringBuffer();
  final stack = <bool>[];
  var skip = false;
  var ucSkip = 1;
  var pendingSkip = 0;
  var i = 0;
  bool isLetter(int c) {
    final lower = c | 0x20;
    return lower >= 97 && lower <= 122;
  }

  bool isDigit(int c) => c >= 48 && c <= 57;
  void put(int code) {
    if (pendingSkip > 0) {
      pendingSkip--;
      return;
    }
    if (!skip) out.writeCharCode(code);
  }

  while (i < rtf.length) {
    final c = rtf.codeUnitAt(i);
    if (c == 123) {
      stack.add(skip);
      i++;
      continue;
    }
    if (c == 125) {
      skip = stack.isEmpty ? false : stack.removeLast();
      i++;
      continue;
    }
    if (c == 92) {
      i++;
      if (i >= rtf.length) break;
      final n = rtf.codeUnitAt(i);
      if (n == 92 || n == 123 || n == 125) {
        put(n);
        i++;
        continue;
      }
      if (n == 42) {
        skip = true;
        i++;
        continue;
      }
      if (n == 39) {
        final code = i + 2 < rtf.length ? int.tryParse(rtf.substring(i + 1, i + 3), radix: 16) : null;
        if (code != null) put(code);
        i += 3;
        continue;
      }
      if (n == 126) {
        put(0xA0);
        i++;
        continue;
      }
      if (!isLetter(n)) {
        if (n == 10 || n == 13) put(10);
        i++;
        continue;
      }
      var j = i;
      while (j < rtf.length && isLetter(rtf.codeUnitAt(j))) {
        j++;
      }
      final word = rtf.substring(i, j);
      var k = j;
      if (k < rtf.length && rtf.codeUnitAt(k) == 45) k++;
      while (k < rtf.length && isDigit(rtf.codeUnitAt(k))) {
        k++;
      }
      final param = k > j ? int.tryParse(rtf.substring(j, k)) : null;
      if (k < rtf.length && rtf.codeUnitAt(k) == 32) k++;
      i = k;
      if (skipped.contains(word)) {
        skip = true;
        continue;
      }
      switch (word) {
        case 'par' || 'line' || 'row' || 'sect' || 'page':
          put(10);
        case 'tab' || 'cell':
          put(9);
        case 'emdash':
          put(0x2014);
        case 'endash':
          put(0x2013);
        case 'bullet':
          put(0x2022);
        case 'lquote':
          put(0x2018);
        case 'rquote':
          put(0x2019);
        case 'ldblquote':
          put(0x201C);
        case 'rdblquote':
          put(0x201D);
        case 'uc':
          ucSkip = param ?? 1;
        case 'u':
          if (param != null) {
            if (!skip) out.writeCharCode(param < 0 ? param + 65536 : param);
            pendingSkip = ucSkip;
          }
        default:
          break;
      }
      continue;
    }
    if (c == 10 || c == 13) {
      i++;
      continue;
    }
    put(c);
    i++;
  }
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
