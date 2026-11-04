class TerminalMacroItem {
  final String id;
  String name;
  String trigger;
  String replacement;
  bool executeImmediately;
  String? secretValue;
  bool copySecretToClipboard;
  int autoClearClipboardSeconds;
  DateTime createdAt;
  DateTime updatedAt;

  TerminalMacroItem({
    required this.id,
    required this.name,
    required this.trigger,
    required this.replacement,
    this.executeImmediately = true,
    this.secretValue,
    this.copySecretToClipboard = false,
    this.autoClearClipboardSeconds = 60,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  /// Normalized trigger string without leading colons (e.g. "send" for "::send")
  String get cleanTrigger => trigger.replaceFirst(RegExp(r'^:+'), '').trim();

  /// Formatted trigger with :: prefix (e.g. "::send")
  String get formattedTrigger => '::$cleanTrigger';

  /// Interpolates placeholders in [replacement] with arguments from [rawArgs].
  /// Supported placeholders:
  /// - {1}, {2}, {3}, etc. for positional arguments
  /// - {file} or {filename} as alias for {1}
  /// - {args} for the entire argument string
  /// If no placeholders are present in [replacement], but [rawArgs] is not empty,
  /// the arguments are appended with a leading space.
  String interpolate(String rawArgs) {
    final trimmedArgs = rawArgs.trim();
    if (trimmedArgs.isEmpty) {
      // Remove unused placeholders
      var result = replacement;
      result = result.replaceAll(RegExp(r'\{args\}', caseSensitive: false), '');
      result = result.replaceAll(RegExp(r'\{file(name)?\}', caseSensitive: false), '');
      result = result.replaceAll(RegExp(r'\{\d+\}'), '');
      return result;
    }

    final tokens = _parseTokens(trimmedArgs);
    var result = replacement;
    bool placeholderReplaced = false;

    // Replace {args}
    if (result.contains(RegExp(r'\{args\}', caseSensitive: false))) {
      result = result.replaceAll(RegExp(r'\{args\}', caseSensitive: false), trimmedArgs);
      placeholderReplaced = true;
    }

    // Replace {file} or {filename}
    if (result.contains(RegExp(r'\{file(name)?\}', caseSensitive: false))) {
      final fileVal = tokens.isNotEmpty ? tokens[0] : '';
      result = result.replaceAll(RegExp(r'\{file(name)?\}', caseSensitive: false), fileVal);
      placeholderReplaced = true;
    }

    // Replace {1}, {2}, {3}, etc.
    for (int i = 0; i < tokens.length; i++) {
      final placeholder = '{${i + 1}}';
      if (result.contains(placeholder)) {
        result = result.replaceAll(placeholder, tokens[i]);
        placeholderReplaced = true;
      }
    }

    // Clean up any remaining numeric placeholders that weren't provided (e.g. {2})
    result = result.replaceAll(RegExp(r'\{\d+\}'), '');

    // If no placeholders were defined in replacement, append the raw arguments
    if (!placeholderReplaced && trimmedArgs.isNotEmpty) {
      result = '$result $trimmedArgs';
    }

    return result;
  }

  /// Parses argument string respecting quoted substrings (e.g. "my file.txt" or 'my file.txt')
  static List<String> _parseTokens(String input) {
    final List<String> tokens = [];
    final StringBuffer current = StringBuffer();
    bool inSingleQuote = false;
    bool inDoubleQuote = false;

    for (int i = 0; i < input.length; i++) {
      final char = input[i];

      if (char == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (char == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      } else if (char.trim().isEmpty && !inSingleQuote && !inDoubleQuote) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
      } else {
        current.write(char);
      }
    }

    if (current.isNotEmpty) {
      tokens.add(current.toString());
    }

    return tokens;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trigger': cleanTrigger,
        'replacement': replacement,
        'execute_immediately': executeImmediately,
        'secret_value': secretValue,
        'copy_secret_to_clipboard': copySecretToClipboard,
        'auto_clear_clipboard_seconds': autoClearClipboardSeconds,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory TerminalMacroItem.fromJson(Map<String, dynamic> json) {
    return TerminalMacroItem(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      trigger: json['trigger'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
      executeImmediately: json['execute_immediately'] as bool? ?? true,
      secretValue: json['secret_value'] as String?,
      copySecretToClipboard: json['copy_secret_to_clipboard'] as bool? ?? false,
      autoClearClipboardSeconds: json['auto_clear_clipboard_seconds'] as int? ?? 60,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }
}
