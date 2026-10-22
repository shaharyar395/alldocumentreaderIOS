import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Shows the app's own small HTML texts (FAQ answers, terms of use) as rich text:
/// `<b>`/`<strong>`, `<i>`/`<em>`, `<p>`, `<br>`, `<h1>`…`<h6>` and `<a href>`. Other tags are
/// dropped, entities like `&amp;` are decoded. Links call [onLink] with their href.
class HtmlText extends StatefulWidget {
  const HtmlText(this.html, {super.key, this.style, this.linkColor, this.onLink, this.textAlign = TextAlign.start});

  final String html;
  final TextStyle? style;
  final Color? linkColor;
  final void Function(String href)? onLink;
  final TextAlign textAlign;

  @override
  State<HtmlText> createState() => _HtmlTextState();
}

class _HtmlTextState extends State<HtmlText> {
  List<HtmlSegment> _segments = const [];
  final Map<int, TapGestureRecognizer> _recognizers = {};

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(covariant HtmlText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html || oldWidget.onLink != widget.onLink) _parse();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _parse() {
    _clearRecognizers();
    _segments = parseSimpleHtml(widget.html);
    for (var i = 0; i < _segments.length; i++) {
      final href = _segments[i].href;
      if (href == null) continue;
      _recognizers[i] = TapGestureRecognizer()..onTap = () => widget.onLink?.call(href);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(widget.style);
    final linkColor = widget.linkColor ?? Theme.of(context).colorScheme.primary;
    final spans = <InlineSpan>[];
    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      var style = const TextStyle();
      if (seg.bold || seg.heading) style = style.copyWith(fontWeight: FontWeight.w700);
      if (seg.italic) style = style.copyWith(fontStyle: FontStyle.italic);
      if (seg.heading) style = style.copyWith(fontSize: (base.fontSize ?? 14) * 1.12);
      if (seg.href != null) {
        style = style.copyWith(color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor);
      }
      spans.add(TextSpan(text: seg.text, style: style, recognizer: _recognizers[i]));
    }
    return Text.rich(TextSpan(style: base, children: spans), textAlign: widget.textAlign);
  }
}

/// One run of text with the same formatting.
class HtmlSegment {
  const HtmlSegment(this.text, {this.bold = false, this.italic = false, this.heading = false, this.href});

  final String text;
  final bool bold;
  final bool italic;
  final bool heading;
  final String? href;
}

final _tagPattern = RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>');
final _hrefPattern = RegExp(r'''href\s*=\s*["']([^"']*)["']''', caseSensitive: false);

/// Splits [html] into formatted runs (see [HtmlText]).
List<HtmlSegment> parseSimpleHtml(String html) {
  final segments = <HtmlSegment>[];
  final all = StringBuffer();
  final buf = StringBuffer();
  var bold = 0;
  var italic = 0;
  var heading = 0;
  String? href;

  void flush() {
    if (buf.isEmpty) return;
    segments.add(HtmlSegment(buf.toString(), bold: bold > 0, italic: italic > 0, heading: heading > 0, href: href));
    buf.clear();
  }

  void write(String text) {
    if (text.isEmpty) return;
    buf.write(text);
    all.write(text);
  }

  // makes the text so far end with [count] line breaks (nothing at the very start)
  void lineBreaks(int count) {
    final text = all.toString();
    if (text.trim().isEmpty) return;
    var trailing = 0;
    for (var i = text.length - 1; i >= 0 && text[i] == '\n'; i--) {
      trailing++;
    }
    if (trailing < count) write('\n' * (count - trailing));
  }

  var pos = 0;
  for (final match in _tagPattern.allMatches(html)) {
    write(decodeHtmlEntities(html.substring(pos, match.start)));
    pos = match.end;
    final closing = match.group(1) == '/';
    final name = match.group(2)!.toLowerCase();
    switch (name) {
      case 'b' || 'strong':
        flush();
        bold = math.max(0, bold + (closing ? -1 : 1));
      case 'i' || 'em':
        flush();
        italic = math.max(0, italic + (closing ? -1 : 1));
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        if (closing) {
          flush();
          heading = math.max(0, heading - 1);
          lineBreaks(1);
        } else {
          lineBreaks(2);
          flush();
          heading++;
        }
      case 'p' || 'div':
        lineBreaks(2);
      case 'br':
        write('\n');
      case 'li':
        if (!closing) {
          lineBreaks(1);
          write('• ');
        }
      case 'a':
        flush();
        href = closing ? null : _hrefPattern.firstMatch(match.group(3) ?? '')?.group(1);
      default:
        break;
    }
  }
  write(decodeHtmlEntities(html.substring(pos)));
  flush();
  // no empty lines at the end
  while (segments.isNotEmpty) {
    final last = segments.last;
    final trimmed = last.text.replaceFirst(RegExp(r'\n+$'), '');
    if (trimmed == last.text) break;
    segments.removeLast();
    if (trimmed.isNotEmpty) {
      segments.add(HtmlSegment(trimmed, bold: last.bold, italic: last.italic, heading: last.heading, href: last.href));
      break;
    }
  }
  return segments;
}

final _entityPattern = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

String decodeHtmlEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entityPattern, (match) {
    final code = match.group(1)!;
    if (code.startsWith('#x') || code.startsWith('#X')) {
      final value = int.tryParse(code.substring(2), radix: 16);
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    if (code.startsWith('#')) {
      final value = int.tryParse(code.substring(1));
      return value == null ? match.group(0)! : String.fromCharCode(value);
    }
    return switch (code) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => ' ',
      _ => match.group(0)!,
    };
  });
}
