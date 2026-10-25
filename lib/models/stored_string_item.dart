class StoredStringItem {
  final String id;
  String label;
  String value;
  DateTime createdAt;
  DateTime updatedAt;

  StoredStringItem({
    required this.id,
    this.label = '',
    required this.value,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'value': value,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory StoredStringItem.fromJson(Map<String, dynamic> json) {
    return StoredStringItem(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      value: json['value'] as String? ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }
}
