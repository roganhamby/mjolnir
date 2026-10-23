import 'package:flutter/material.dart';

enum TaskImportance {
  none,
  low,
  medium,
  high,
  priority;

  String get label {
    switch (this) {
      case TaskImportance.none:
        return 'None';
      case TaskImportance.low:
        return 'Low';
      case TaskImportance.medium:
        return 'Medium';
      case TaskImportance.high:
        return 'High';
      case TaskImportance.priority:
        return 'Priority';
    }
  }

  Color get color {
    switch (this) {
      case TaskImportance.none:
        return Colors.grey;
      case TaskImportance.low:
        return Colors.lightBlueAccent;
      case TaskImportance.medium:
        return Colors.amberAccent;
      case TaskImportance.high:
        return Colors.deepOrangeAccent;
      case TaskImportance.priority:
        return Colors.redAccent;
    }
  }

  IconData get icon {
    switch (this) {
      case TaskImportance.none:
        return Icons.remove;
      case TaskImportance.low:
        return Icons.keyboard_arrow_down;
      case TaskImportance.medium:
        return Icons.drag_handle;
      case TaskImportance.high:
        return Icons.keyboard_arrow_up;
      case TaskImportance.priority:
        return Icons.priority_high;
    }
  }
}

class TaskItem {
  final String id;
  String title;
  TaskImportance importance;
  DateTime? dueDate;
  String? assignedTabId;
  DateTime createdAt;
  DateTime updatedAt;

  TaskItem({
    required this.id,
    required this.title,
    this.importance = TaskImportance.none,
    this.dueDate,
    this.assignedTabId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  bool get isOverdue {
    if (dueDate == null) return false;
    return DateTime.now().isAfter(dueDate!.toLocal());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'importance': importance.name,
        'due_date': dueDate?.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    return TaskItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled Task',
      importance: TaskImportance.values.firstWhere(
        (e) => e.name == json['importance'],
        orElse: () => TaskImportance.none,
      ),
      dueDate: json['due_date'] != null
          ? DateTime.tryParse(json['due_date'] as String)?.toLocal()
          : null,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)?.toUtc() ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }
}
