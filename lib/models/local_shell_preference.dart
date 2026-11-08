class LocalShellPreference {
  final String machineName;
  String terminalTheme;
  double terminalFontSize;
  DateTime updatedAt;

  LocalShellPreference({
    required this.machineName,
    this.terminalTheme = 'Default Dark',
    this.terminalFontSize = 13.0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'machine_name': machineName,
        'terminal_theme': terminalTheme,
        'terminal_font_size': terminalFontSize,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory LocalShellPreference.fromJson(Map<String, dynamic> json) {
    return LocalShellPreference(
      machineName: (json['machine_name'] as String?)?.trim() ?? 'localhost',
      terminalTheme: json['terminal_theme'] as String? ?? 'Default Dark',
      terminalFontSize: (json['terminal_font_size'] as num?)?.toDouble() ?? 13.0,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ??
              DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }
}
