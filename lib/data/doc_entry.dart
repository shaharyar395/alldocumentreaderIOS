import 'dart:convert';

import 'package:path/path.dart' as p;

enum DocKind { pdf, word, excel, ppt, txt, image, other }

enum SortField { name, date, size }

enum SortDir { asc, desc }

/// Every extension the app lists, by type — the same lists as the Android app's FileType.kt
/// (plus .tsv, which the sheet reader opens as Excel). Anything else is [DocKind.other]: never
/// scanned, listed or counted (only Directories → All documents shows such files).
const Map<DocKind, Set<String>> docExtensions = {
  DocKind.pdf: {'pdf'},
  DocKind.word: {'doc', 'docx', 'docm', 'dot', 'dotx', 'rtf', 'odt'},
  DocKind.excel: {'xls', 'xlsx', 'xlsm', 'xlt', 'xltx', 'csv', 'ods', 'tsv'},
  DocKind.ppt: {'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'pot', 'potx', 'odp'},
  DocKind.txt: {'txt', 'log', 'md', 'json', 'xml'},
  DocKind.image: {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif'},
};

/// All supported extensions (without the dot), for the device scan.
final List<String> supportedExtensions = [for (final set in docExtensions.values) ...set];

final Map<String, DocKind> _kindByExt = {
  for (final entry in docExtensions.entries)
    for (final ext in entry.value) ext: entry.key,
};

DocKind kindForName(String name) {
  final lower = name.toLowerCase();
  final slash = lower.lastIndexOf('/');
  final base = slash == -1 ? lower : lower.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot == -1) return DocKind.other;
  return _kindByExt[base.substring(dot + 1)] ?? DocKind.other;
}

/// The MIME type for a file name (for "Open with" / share); falls back to the type's generic one.
String mimeForName(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot == -1 ? '' : lower.substring(dot + 1);
  const known = {
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'dot': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'docm': 'application/vnd.ms-word.document.macroEnabled.12',
    'dotx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.template',
    'rtf': 'application/rtf',
    'odt': 'application/vnd.oasis.opendocument.text',
    'xls': 'application/vnd.ms-excel',
    'xlt': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'xlsm': 'application/vnd.ms-excel.sheet.macroEnabled.12',
    'xltx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.template',
    'csv': 'text/csv',
    'tsv': 'text/tab-separated-values',
    'ods': 'application/vnd.oasis.opendocument.spreadsheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pps': 'application/vnd.ms-powerpoint',
    'pot': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'pptm': 'application/vnd.ms-powerpoint.presentation.macroEnabled.12',
    'ppsx': 'application/vnd.openxmlformats-officedocument.presentationml.slideshow',
    'potx': 'application/vnd.openxmlformats-officedocument.presentationml.template',
    'odp': 'application/vnd.oasis.opendocument.presentation',
    'txt': 'text/plain',
    'log': 'text/plain',
    'md': 'text/markdown',
    'json': 'application/json',
    'xml': 'text/xml',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'heic': 'image/heic',
    'heif': 'image/heif',
  };
  final mime = known[ext];
  if (mime != null) return mime;
  return switch (kindForName(name)) {
    DocKind.image => 'image/*',
    _ => '*/*',
  };
}

/// An extension (without the dot) for a MIME type, for incoming files that have no extension
/// (like the Android app's OpenDocumentActivity.extFromMime). Empty when unknown.
String extensionForMime(String? mime) {
  final value = (mime ?? '').toLowerCase().split(';').first.trim();
  return switch (value) {
    'application/pdf' => 'pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
    'application/msword' => 'doc',
    'application/rtf' || 'text/rtf' => 'rtf',
    'application/vnd.oasis.opendocument.text' => 'odt',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx',
    'application/vnd.ms-powerpoint' => 'ppt',
    'application/vnd.oasis.opendocument.presentation' => 'odp',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
    'application/vnd.ms-excel' => 'xls',
    'application/vnd.oasis.opendocument.spreadsheet' => 'ods',
    'text/csv' || 'text/comma-separated-values' => 'csv',
    'text/tab-separated-values' => 'tsv',
    'text/plain' => 'txt',
    'text/markdown' => 'md',
    'application/json' => 'json',
    'text/xml' || 'application/xml' => 'xml',
    'image/jpeg' => 'jpg',
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    'image/bmp' => 'bmp',
    'image/heic' => 'heic',
    'image/heif' => 'heif',
    _ => '',
  };
}

class DocEntry {
  DocEntry({
    required this.id,
    required this.name,
    required this.relativePath,
    required this.kind,
    required this.modified,
    required this.bytes,
    required this.openedAt,
    this.bookmarked = false,
    this.isNew = false,
    this.deletedAt,
    this.addedAt,
    this.originalPath = '',
  });

  /// The app's own library folder (set by FileLibrary); [relativePath]s that are not absolute
  /// are relative to it (files copied in by older versions of the app).
  static String libraryRoot = '';

  final String id;
  final String name;

  /// Where the file is: an absolute path for real files on the device (read in place), or a
  /// path relative to [libraryRoot] for the app's own older library copies.
  final String relativePath;
  final DocKind kind;
  final DateTime modified;
  final int bytes;

  /// When the file was last opened (for Recent: the open time).
  final DateTime openedAt;
  final bool bookmarked;
  final bool isNew;
  final DateTime? deletedAt;

  /// When the file came into the app's lists (null for entries saved by older versions).
  final DateTime? addedAt;

  /// Recycle bin: the full path the file had before it was deleted (restore puts it back there).
  final String originalPath;

  bool get inBin => deletedAt != null;

  /// File size in bytes (same as [bytes]).
  int get size => bytes;

  /// The absolute path of the file, as shown in Info and the ⋮ menu header.
  String get fullPath {
    if (p.isAbsolute(relativePath) || libraryRoot.isEmpty) return relativePath;
    return p.normalize(p.join(libraryRoot, relativePath));
  }

  int daysLeft() {
    final deleted = deletedAt;
    if (deleted == null) return 30;
    final elapsed = DateTime.now().difference(deleted).inDays;
    final left = 30 - elapsed;
    return left < 0 ? 0 : left;
  }

  DocEntry copyWith({
    String? name,
    String? relativePath,
    DocKind? kind,
    DateTime? modified,
    int? bytes,
    DateTime? openedAt,
    bool? bookmarked,
    bool? isNew,
    DateTime? deletedAt,
    DateTime? addedAt,
    String? originalPath,
    bool clearDeleted = false,
  }) {
    return DocEntry(
      id: id,
      name: name ?? this.name,
      relativePath: relativePath ?? this.relativePath,
      kind: kind ?? this.kind,
      modified: modified ?? this.modified,
      bytes: bytes ?? this.bytes,
      openedAt: openedAt ?? this.openedAt,
      bookmarked: bookmarked ?? this.bookmarked,
      isNew: isNew ?? this.isNew,
      deletedAt: clearDeleted ? null : (deletedAt ?? this.deletedAt),
      addedAt: addedAt ?? this.addedAt,
      originalPath: clearDeleted ? '' : (originalPath ?? this.originalPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'relativePath': relativePath,
        'kind': kind.name,
        'modified': modified.toIso8601String(),
        'bytes': bytes,
        'openedAt': openedAt.toIso8601String(),
        'bookmarked': bookmarked,
        'isNew': isNew,
        'deletedAt': deletedAt?.toIso8601String(),
        'addedAt': addedAt?.toIso8601String(),
        if (originalPath.isNotEmpty) 'originalPath': originalPath,
      };

  factory DocEntry.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    return DocEntry(
      id: json['id'] as String,
      name: name,
      relativePath: json['relativePath'] as String,
      // re-derived from the name: older versions knew fewer extensions
      kind: kindForName(name) == DocKind.other
          ? DocKind.values.asNameMap()[json['kind'] as String? ?? ''] ?? DocKind.other
          : kindForName(name),
      modified: DateTime.parse(json['modified'] as String),
      bytes: json['bytes'] as int,
      openedAt: DateTime.parse(json['openedAt'] as String),
      bookmarked: json['bookmarked'] as bool? ?? false,
      isNew: json['isNew'] as bool? ?? false,
      deletedAt: json['deletedAt'] == null ? null : DateTime.parse(json['deletedAt'] as String),
      addedAt: json['addedAt'] == null ? null : DateTime.tryParse(json['addedAt'] as String),
      originalPath: json['originalPath'] as String? ?? '',
    );
  }
}

List<DocEntry> decodeEntries(String raw) {
  final list = json.decode(raw) as List<dynamic>;
  return list.map((item) => DocEntry.fromJson(item as Map<String, dynamic>)).toList();
}

String encodeEntries(List<DocEntry> entries) {
  return json.encode(entries.map((e) => e.toJson()).toList());
}

List<DocEntry> sortDocs(List<DocEntry> input, SortField field, SortDir dir) {
  final list = [...input];
  list.sort((a, b) {
    final cmp = switch (field) {
      SortField.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortField.date => a.modified.compareTo(b.modified),
      SortField.size => a.bytes.compareTo(b.bytes),
    };
    return dir == SortDir.asc ? cmp : -cmp;
  });
  return list;
}
