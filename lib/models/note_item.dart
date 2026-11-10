/// A plain-text (ASCII) note stored in the encrypted vault.
///
/// Notes can be linked to SSH / SFTP tabs "by title" via [linkedTitles].
/// Matching is case-insensitive and ignores the trailing connection-type
/// suffix that Mjölnir appends to tab titles (e.g. " (SSH)", " (SFTP)"), so a
/// note linked to "Prod DB" shows up for both "Prod DB (SSH)" and
/// "Prod DB (SFTP)".
class NoteItem {
  final String id;
  String title;
  String content;
  List<String> linkedTitles;
  DateTime createdAt;
  DateTime updatedAt;

  NoteItem({
    required this.id,
    this.title = '',
    this.content = '',
    List<String>? linkedTitles,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : linkedTitles = linkedTitles ?? [],
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  static final RegExp _suffixPattern =
      RegExp(r'\s*\((ssh|sftp|local)\)\s*$', caseSensitive: false);

  /// Normalizes a tab title (or link title) for comparison: strips the
  /// " (SSH)" / " (SFTP)" / " (Local)" suffix, trims, collapses whitespace
  /// and lowercases.
  static String normalizeTitle(String title) {
    return title
        .replaceFirst(_suffixPattern, '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toLowerCase();
  }

  /// Returns the user-facing link title for a tab title (suffix removed,
  /// original casing preserved).
  static String linkTitleForTab(String tabTitle) {
    return tabTitle.replaceFirst(_suffixPattern, '').trim();
  }

  /// Display name used in menus and headers.
  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    final firstLine = content
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return 'Untitled note';
    return firstLine.length > 40 ? '${firstLine.substring(0, 40)}...' : firstLine;
  }

  /// True if this note is linked to the given tab title.
  bool matchesTabTitle(String tabTitle) {
    final target = normalizeTitle(tabTitle);
    if (target.isEmpty) return false;
    return linkedTitles.any((l) => normalizeTitle(l) == target);
  }

  /// Links this note to [tabTitle] (if not already linked). Returns true if
  /// a new link was added.
  bool linkToTabTitle(String tabTitle) {
    if (matchesTabTitle(tabTitle)) return false;
    final link = linkTitleForTab(tabTitle);
    if (link.isEmpty) return false;
    linkedTitles.add(link);
    return true;
  }

  /// Removes any link that matches [tabTitle]. Returns true if removed.
  bool unlinkTabTitle(String tabTitle) {
    final target = normalizeTitle(tabTitle);
    final before = linkedTitles.length;
    linkedTitles.removeWhere((l) => normalizeTitle(l) == target);
    return linkedTitles.length != before;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'linked_titles': linkedTitles,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory NoteItem.fromJson(Map<String, dynamic> json) {
    return NoteItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      linkedTitles: (json['linked_titles'] as List<dynamic>? ?? [])
          .whereType<String>()
          .toList(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }

  /// Formats this note as Markdown for export.
  /// If the title is present and not already the first H1 heading in [content],
  /// prepends `# [title]` to the output.
  String toMarkdown() {
    final trimmedTitle = title.trim();
    final trimmedContent = content.trim();
    if (trimmedTitle.isEmpty) return content;
    final lines = trimmedContent.split('\n');
    final firstLine = lines.isNotEmpty ? lines.first.trim() : '';
    if (firstLine.startsWith('# ') && firstLine.substring(2).trim().toLowerCase() == trimmedTitle.toLowerCase()) {
      return content;
    }
    if (trimmedContent.isEmpty) return '# $trimmedTitle\n';
    return '# $trimmedTitle\n\n$content';
  }

  /// Creates a [NoteItem] from imported Markdown content.
  /// Extracts the title from the first `# ` heading if present, otherwise uses [defaultTitle].
  static NoteItem fromMarkdown(
    String markdown, {
    String? defaultTitle,
    String? id,
    List<String>? linkedTitles,
  }) {
    final trimmed = markdown.trim();
    var parsedTitle = defaultTitle?.trim() ?? '';
    final lines = trimmed.split('\n');
    if (lines.isNotEmpty && lines.first.trim().startsWith('# ')) {
      final h1Title = lines.first.trim().substring(2).trim();
      if (h1Title.isNotEmpty) {
        parsedTitle = h1Title;
      }
    }

    if (parsedTitle.isEmpty) {
      parsedTitle = defaultTitle ?? 'Imported Note';
    }

    return NoteItem(
      id: id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: parsedTitle,
      content: markdown,
      linkedTitles: linkedTitles,
    );
  }
}
