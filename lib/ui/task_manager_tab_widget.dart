import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/task_item.dart';
import '../theme/app_color_schemes.dart';

class AssignableTabInfo {
  final String id;
  final String title;
  final String type; // 'ssh' or 'sftp'

  const AssignableTabInfo({
    required this.id,
    required this.title,
    required this.type,
  });
}

/// Compact interactive task pill rendered in the free space of an SSH or SFTP tab's bar.
class AssignedTabTaskBanner extends StatefulWidget {
  final TaskItem task;
  final VoidCallback onCompleteTask;
  final VoidCallback onUnassignTask;
  final ValueChanged<TaskItem>? onTaskChanged;

  const AssignedTabTaskBanner({
    super.key,
    required this.task,
    required this.onCompleteTask,
    required this.onUnassignTask,
    this.onTaskChanged,
  });

  @override
  State<AssignedTabTaskBanner> createState() => _AssignedTabTaskBannerState();
}

class _AssignedTabTaskBannerState extends State<AssignedTabTaskBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Periodically refresh so due date turns red immediately when the minute passes
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _showSubtasksDialog(BuildContext context) async {
    final scheme = AppColorScheme.of(context);
    final task = widget.task;
    final newSubtaskCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          void addSubtask() {
            final title = newSubtaskCtrl.text.trim();
            if (title.isEmpty) return;
            setDialogState(() {
              task.subtasks.add(SubTaskItem(id: const Uuid().v4(), title: title));
              newSubtaskCtrl.clear();
            });
            setState(() {});
            widget.onTaskChanged?.call(task);
          }

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.checklist, size: 18, color: scheme.accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Subtasks: ${task.title}',
                    style: const TextStyle(fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (task.subtasks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No subtasks yet. Add one below.',
                        style: TextStyle(fontSize: 12, color: scheme.mutedText),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: task.subtasks.length,
                        itemBuilder: (ctx, i) {
                          final sub = task.subtasks[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: sub.isCompleted,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (val) {
                                      setDialogState(() {
                                        sub.isCompleted = val ?? false;
                                      });
                                      setState(() {});
                                      widget.onTaskChanged?.call(task);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        sub.isCompleted = !sub.isCompleted;
                                      });
                                      setState(() {});
                                      widget.onTaskChanged?.call(task);
                                    },
                                    child: Text(
                                      sub.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: sub.isCompleted
                                            ? scheme.mutedText
                                            : scheme.primaryText,
                                        decoration: sub.isCompleted
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.close, size: 15, color: scheme.mutedText),
                                  tooltip: 'Remove Subtask',
                                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                  padding: EdgeInsets.zero,
                                  onPressed: () {
                                    setDialogState(() {
                                      task.subtasks.removeAt(i);
                                    });
                                    setState(() {});
                                    widget.onTaskChanged?.call(task);
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: newSubtaskCtrl,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            hintText: 'Add a subtask...',
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => addSubtask(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline, size: 20, color: scheme.accentColor),
                        tooltip: 'Add Subtask',
                        onPressed: addSubtask,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final task = widget.task;
    final isOverdue = task.isOverdue;
    final dueDateStr = task.dueDate != null
        ? DateFormat('MMM d, HH:mm').format(task.dueDate!.toLocal())
        : null;
    final totalSubtasks = task.subtasks.length;
    final completedSubtasks = task.completedSubtaskCount;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isOverdue
            ? Colors.redAccent.withAlpha(35)
            : scheme.elevatedSurface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isOverdue
              ? Colors.redAccent.withAlpha(180)
              : task.importance.color.withAlpha(130),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: false,
              onChanged: (_) => widget.onCompleteTask(),
              visualDensity: VisualDensity.compact,
              side: BorderSide(
                color: isOverdue ? Colors.redAccent : scheme.mutedText,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (task.importance != TaskImportance.none) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: task.importance.color.withAlpha(40),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                task.importance.label.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: task.importance.color,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Tooltip(
              message: 'Assigned Task: ${task.title}',
              child: Text(
                task.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isOverdue ? Colors.redAccent.shade100 : scheme.primaryText,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _showSubtasksDialog(context),
            borderRadius: BorderRadius.circular(4),
            child: Tooltip(
              message: totalSubtasks > 0
                  ? 'Subtasks ($completedSubtasks/$totalSubtasks completed) — click to manage'
                  : 'Add or manage subtasks',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: totalSubtasks > 0 && completedSubtasks == totalSubtasks
                      ? Colors.greenAccent.withAlpha(35)
                      : scheme.scaffoldBackground,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: totalSubtasks > 0 && completedSubtasks == totalSubtasks
                        ? Colors.greenAccent.withAlpha(140)
                        : scheme.borderColor,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.checklist,
                      size: 11,
                      color: totalSubtasks > 0 && completedSubtasks == totalSubtasks
                          ? Colors.greenAccent
                          : scheme.accentColor,
                    ),
                    if (totalSubtasks > 0) ...[
                      const SizedBox(width: 3),
                      Text(
                        '$completedSubtasks/$totalSubtasks',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: completedSubtasks == totalSubtasks
                              ? Colors.greenAccent
                              : scheme.primaryText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (dueDateStr != null) ...[
            const SizedBox(width: 8),
            Icon(
              isOverdue ? Icons.warning_amber_rounded : Icons.schedule,
              size: 12,
              color: isOverdue ? Colors.redAccent : scheme.mutedText,
            ),
            const SizedBox(width: 3),
            Text(
              dueDateStr,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isOverdue ? FontWeight.bold : FontWeight.normal,
                color: isOverdue ? Colors.redAccent : scheme.mutedText,
              ),
            ),
          ],
          const SizedBox(width: 4),
          InkWell(
            onTap: widget.onUnassignTask,
            borderRadius: BorderRadius.circular(4),
            child: Tooltip(
              message: 'Unassign task from tab',
              child: Padding(
                padding: const EdgeInsets.all(2.0),
                child: Icon(
                  Icons.close,
                  size: 13,
                  color: scheme.mutedText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TaskManagerTabWidget extends StatefulWidget {
  final List<TaskItem> tasks;
  final List<AssignableTabInfo> availableTabs;
  final Future<void> Function(TaskItem task) onSaveTask;
  final Future<void> Function(String taskId) onCompleteTask;
  final void Function(TaskItem task, String? tabId) onAssignTaskToTab;

  const TaskManagerTabWidget({
    super.key,
    required this.tasks,
    required this.availableTabs,
    required this.onSaveTask,
    required this.onCompleteTask,
    required this.onAssignTaskToTab,
  });

  @override
  State<TaskManagerTabWidget> createState() => _TaskManagerTabWidgetState();
}

class _TaskManagerTabWidgetState extends State<TaskManagerTabWidget> {
  final TextEditingController _newTaskController = TextEditingController();
  final Map<String, TextEditingController> _subtaskInputControllers = {};
  final Set<String> _collapsedTaskIds = {};
  final Set<String> _addingSubtaskForIds = {};
  TaskImportance _newTaskImportance = TaskImportance.none;
  DateTime? _newTaskDueDate;
  String? _newTaskAssignedTabId;
  Timer? _clockTimer;
  String _sortBy = 'created'; // 'created', 'importance', 'dueDate'

  @override
  void initState() {
    super.initState();
    // Refresh every 5 seconds so overdue dates turn red right when the minute passes
    _clockTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _newTaskController.dispose();
    for (final ctrl in _subtaskInputControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  TextEditingController _getSubtaskController(String taskId) {
    return _subtaskInputControllers.putIfAbsent(
      taskId,
      () => TextEditingController(),
    );
  }

  Future<void> _addSubtaskToTask(TaskItem task) async {
    final ctrl = _getSubtaskController(task.id);
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    setState(() {
      task.subtasks.add(SubTaskItem(id: const Uuid().v4(), title: title));
      ctrl.clear();
      _collapsedTaskIds.remove(task.id);
    });
    await widget.onSaveTask(task);
  }

  Future<void> _toggleSubtask(TaskItem task, SubTaskItem subtask) async {
    setState(() {
      subtask.isCompleted = !subtask.isCompleted;
    });
    await widget.onSaveTask(task);
  }

  Future<void> _deleteSubtask(TaskItem task, SubTaskItem subtask) async {
    setState(() {
      task.subtasks.removeWhere((s) => s.id == subtask.id);
    });
    await widget.onSaveTask(task);
  }

  Future<void> _editSubtaskDialog(TaskItem task, SubTaskItem subtask) async {
    final ctrl = TextEditingController(text: subtask.title);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Subtask'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Subtask Description',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) async {
              final text = ctrl.text.trim();
              if (text.isNotEmpty) {
                setState(() => subtask.title = text);
                await widget.onSaveTask(task);
                if (ctx.mounted) Navigator.of(ctx).pop();
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              if (text.isEmpty) return;
              setState(() => subtask.title = text);
              await widget.onSaveTask(task);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickDateTime(BuildContext context, [DateTime? initial]) async {
    final now = DateTime.now();
    final initialDate = initial?.toLocal() ?? now.add(const Duration(hours: 1));

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      helpText: 'Select Due Date',
    );

    if (pickedDate == null || !context.mounted) return null;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
      helpText: 'Select Due Time (to the minute)',
    );

    if (pickedTime == null) return null;

    return DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
  }

  Future<void> _handleAddTask() async {
    final title = _newTaskController.text.trim();
    if (title.isEmpty) return;

    final validTabId = widget.availableTabs.any((t) => t.id == _newTaskAssignedTabId)
        ? _newTaskAssignedTabId
        : null;

    final task = TaskItem(
      id: const Uuid().v4(),
      title: title,
      importance: _newTaskImportance,
      dueDate: _newTaskDueDate,
      assignedTabId: validTabId,
    );

    await widget.onSaveTask(task);
    if (validTabId != null) {
      widget.onAssignTaskToTab(task, validTabId);
    }

    if (mounted) {
      setState(() {
        _newTaskController.clear();
        _newTaskImportance = TaskImportance.none;
        _newTaskDueDate = null;
        _newTaskAssignedTabId = null;
      });
    }
  }

  Future<void> _showEditTaskDialog(TaskItem task) async {
    final titleCtrl = TextEditingController(text: task.title);
    final newSubCtrl = TextEditingController();
    TaskImportance selectedImportance = task.importance;
    DateTime? selectedDueDate = task.dueDate;
    String? selectedTabId = widget.availableTabs.any((t) => t.id == task.assignedTabId)
        ? task.assignedTabId
        : null;
    final editedSubtasks = task.subtasks
        .map(
          (s) => SubTaskItem(
            id: s.id,
            title: s.title,
            isCompleted: s.isCompleted,
            createdAt: s.createdAt,
          ),
        )
        .toList();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final scheme = AppColorScheme.of(ctx);
          final isOverdue = selectedDueDate != null &&
              DateTime.now().isAfter(selectedDueDate!.toLocal());

          void addSubtaskInDialog() {
            final subTitle = newSubCtrl.text.trim();
            if (subTitle.isEmpty) return;
            setDialogState(() {
              editedSubtasks.add(
                SubTaskItem(id: const Uuid().v4(), title: subTitle),
              );
              newSubCtrl.clear();
            });
          }

          return AlertDialog(
            title: const Text('Edit Task'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Task Description',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<TaskImportance>(
                      initialValue: selectedImportance,
                      decoration: const InputDecoration(
                        labelText: 'Importance',
                        border: OutlineInputBorder(),
                      ),
                      items: TaskImportance.values.map((imp) {
                        return DropdownMenuItem(
                          value: imp,
                          child: Row(
                            children: [
                              Icon(imp.icon, size: 16, color: imp.color),
                              const SizedBox(width: 8),
                              Text(imp.label, style: TextStyle(color: imp.color)),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedImportance = val);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: Icon(
                              Icons.event,
                              size: 16,
                              color: isOverdue ? Colors.redAccent : Colors.amberAccent,
                            ),
                            label: Text(
                              selectedDueDate != null
                                  ? 'Due: ${DateFormat('MMM d, yyyy HH:mm').format(selectedDueDate!.toLocal())}'
                                  : 'Set Due Date & Time (to the minute)',
                              style: TextStyle(
                                color: isOverdue ? Colors.redAccent : Colors.white,
                                fontWeight: isOverdue ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            onPressed: () async {
                              final picked = await _pickDateTime(ctx, selectedDueDate);
                              if (picked != null) {
                                setDialogState(() => selectedDueDate = picked);
                              }
                            },
                          ),
                        ),
                        if (selectedDueDate != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            tooltip: 'Clear Due Date',
                            onPressed: () => setDialogState(() => selectedDueDate = null),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String?>(
                      initialValue: selectedTabId,
                      decoration: const InputDecoration(
                        labelText: 'Assigned SSH / SFTP Tab',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Unassigned'),
                        ),
                        ...widget.availableTabs.map((tab) {
                          return DropdownMenuItem<String?>(
                            value: tab.id,
                            child: Row(
                              children: [
                                Icon(
                                  tab.type == 'sftp' ? Icons.folder_shared : Icons.terminal,
                                  size: 15,
                                  color: Colors.amberAccent,
                                ),
                                const SizedBox(width: 8),
                                Text(tab.title),
                              ],
                            ),
                          );
                        }),
                      ],
                      onChanged: (val) {
                        setDialogState(() => selectedTabId = val);
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Icon(Icons.checklist, size: 16, color: scheme.accentColor),
                        const SizedBox(width: 6),
                        Text(
                          'Subtasks (${editedSubtasks.where((s) => s.isCompleted).length}/${editedSubtasks.length})',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: scheme.primaryText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (editedSubtasks.isNotEmpty) ...[
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: scheme.scaffoldBackground,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: scheme.borderColor),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: editedSubtasks.length,
                          itemBuilder: (ctx, i) {
                            final sub = editedSubtasks[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Checkbox(
                                      value: sub.isCompleted,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: (val) {
                                        setDialogState(() => sub.isCompleted = val ?? false);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      sub.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: sub.isCompleted
                                            ? scheme.mutedText
                                            : scheme.primaryText,
                                        decoration: sub.isCompleted
                                            ? TextDecoration.lineThrough
                                            : null,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.delete_outline, size: 16, color: scheme.mutedText),
                                    tooltip: 'Remove Subtask',
                                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                    padding: EdgeInsets.zero,
                                    onPressed: () {
                                      setDialogState(() => editedSubtasks.removeAt(i));
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newSubCtrl,
                            style: const TextStyle(fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: 'Add a subtask...',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => addSubtaskInDialog(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add, size: 15),
                          label: const Text('Add'),
                          onPressed: addSubtaskInDialog,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final newTitle = titleCtrl.text.trim();
                  if (newTitle.isEmpty) return;
                  final pendingSub = newSubCtrl.text.trim();
                  if (pendingSub.isNotEmpty) {
                    editedSubtasks.add(
                      SubTaskItem(id: const Uuid().v4(), title: pendingSub),
                    );
                  }
                  task.title = newTitle;
                  task.importance = selectedImportance;
                  task.dueDate = selectedDueDate;
                  task.subtasks = editedSubtasks;
                  widget.onAssignTaskToTab(task, selectedTabId);
                  await widget.onSaveTask(task);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<TaskItem> _getSortedTasks() {
    final list = List<TaskItem>.from(widget.tasks);
    if (_sortBy == 'importance') {
      list.sort((a, b) => b.importance.index.compareTo(a.importance.index));
    } else if (_sortBy == 'dueDate') {
      list.sort((a, b) {
        if (a.dueDate == null && b.dueDate == null) return 0;
        if (a.dueDate == null) return 1;
        if (b.dueDate == null) return -1;
        return a.dueDate!.compareTo(b.dueDate!);
      });
    } else {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = AppColorScheme.of(context);
    final sortedTasks = _getSortedTasks();
    final validNewTaskTabId = widget.availableTabs.any((t) => t.id == _newTaskAssignedTabId)
        ? _newTaskAssignedTabId
        : null;
    final isNewTaskOverdue = _newTaskDueDate != null &&
        DateTime.now().isAfter(_newTaskDueDate!.toLocal());

    return Column(
      children: [
        // Top Header & Add Task Bar
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.panelBackground,
            border: Border(bottom: BorderSide(color: scheme.borderColor)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.task_alt, color: scheme.accentColor, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Task Manager (${widget.tasks.length} Active)',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: scheme.primaryText,
                    ),
                  ),
                  const Spacer(),
                  Text('Sort by: ', style: TextStyle(fontSize: 12, color: scheme.mutedText)),
                  const SizedBox(width: 4),
                  DropdownButton<String>(
                    value: _sortBy,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    style: TextStyle(fontSize: 12, color: scheme.primaryText),
                    dropdownColor: scheme.elevatedSurface,
                    items: const [
                      DropdownMenuItem(value: 'created', child: Text('Newest First')),
                      DropdownMenuItem(value: 'importance', child: Text('Importance')),
                      DropdownMenuItem(value: 'dueDate', child: Text('Due Date')),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _sortBy = val);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Quick Add Task Row
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 280,
                    child: TextField(
                      controller: _newTaskController,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: 'New task description...',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _handleAddTask(),
                    ),
                  ),
                  // Importance Selector
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.borderColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<TaskImportance>(
                        value: _newTaskImportance,
                        isDense: true,
                        dropdownColor: scheme.elevatedSurface,
                        items: TaskImportance.values.map((imp) {
                          return DropdownMenuItem(
                            value: imp,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(imp.icon, size: 15, color: imp.color),
                                const SizedBox(width: 6),
                                Text(
                                  imp.label,
                                  style: TextStyle(fontSize: 12, color: imp.color),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _newTaskImportance = val);
                          }
                        },
                      ),
                    ),
                  ),
                  // Due Date Picker Button (to the minute)
                  OutlinedButton.icon(
                    icon: Icon(
                      Icons.schedule,
                      size: 15,
                      color: isNewTaskOverdue ? Colors.redAccent : scheme.accentColor,
                    ),
                    label: Text(
                      _newTaskDueDate != null
                          ? DateFormat('MMM d, yyyy HH:mm').format(_newTaskDueDate!.toLocal())
                          : 'Due Date & Time',
                      style: TextStyle(
                        fontSize: 12,
                        color: isNewTaskOverdue ? Colors.redAccent : scheme.primaryText,
                        fontWeight: isNewTaskOverdue ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onPressed: () async {
                      final picked = await _pickDateTime(context, _newTaskDueDate);
                      if (picked != null && mounted) {
                        setState(() => _newTaskDueDate = picked);
                      }
                    },
                  ),
                  if (_newTaskDueDate != null)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      tooltip: 'Clear Due Date',
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: () => setState(() => _newTaskDueDate = null),
                    ),
                  // Assign to SSH/SFTP Tab Selector
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.borderColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: validNewTaskTabId,
                        hint: const Text('Assign to Tab', style: TextStyle(fontSize: 12)),
                        isDense: true,
                        dropdownColor: scheme.elevatedSurface,
                        items: [
                          DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Unassigned', style: TextStyle(fontSize: 12, color: scheme.mutedText)),
                          ),
                          ...widget.availableTabs.map((tab) {
                            return DropdownMenuItem<String?>(
                              value: tab.id,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    tab.type == 'sftp' ? Icons.folder_shared : Icons.terminal,
                                    size: 14,
                                    color: scheme.accentColor,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(tab.title, style: const TextStyle(fontSize: 12)),
                                ],
                              ),
                            );
                          }),
                        ],
                        onChanged: (val) => setState(() => _newTaskAssignedTabId = val),
                      ),
                    ),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Task'),
                    onPressed: _handleAddTask,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Task List Body
        Expanded(
          child: sortedTasks.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline, size: 52, color: scheme.mutedText),
                      const SizedBox(height: 12),
                      Text(
                        'No active tasks. Add a task above and optionally assign it to an SSH or SFTP tab.',
                        style: TextStyle(color: scheme.mutedText),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: sortedTasks.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final task = sortedTasks[index];
                    final isOverdue = task.isOverdue;
                    final assignedTab = widget.availableTabs
                        .where((t) => t.id == task.assignedTabId)
                        .firstOrNull;

                    final importanceBadge = Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: task.importance.color.withAlpha(30),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: task.importance.color.withAlpha(100)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<TaskImportance>(
                          value: task.importance,
                          isDense: true,
                          dropdownColor: scheme.elevatedSurface,
                          items: TaskImportance.values.map((imp) {
                            return DropdownMenuItem(
                              value: imp,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(imp.icon, size: 14, color: imp.color),
                                  const SizedBox(width: 4),
                                  Text(
                                    imp.label,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: imp.color,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              task.importance = val;
                              widget.onSaveTask(task);
                            }
                          },
                        ),
                      ),
                    );

                    final dueDateBadge = InkWell(
                      onTap: () async {
                        final picked = await _pickDateTime(context, task.dueDate);
                        if (picked != null && mounted) {
                          task.dueDate = picked;
                          await widget.onSaveTask(task);
                        }
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isOverdue
                              ? Colors.redAccent.withAlpha(40)
                              : scheme.scaffoldBackground,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isOverdue
                                ? Colors.redAccent
                                : scheme.borderColor,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isOverdue ? Icons.error_outline : Icons.schedule,
                              size: 14,
                              color: isOverdue ? Colors.redAccent : scheme.mutedText,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              task.dueDate != null
                                  ? DateFormat('MMM d, yyyy HH:mm').format(task.dueDate!.toLocal())
                                  : 'Set Due Date',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isOverdue ? FontWeight.bold : FontWeight.normal,
                                color: isOverdue
                                    ? Colors.redAccent
                                    : (task.dueDate != null ? scheme.primaryText : scheme.mutedText),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );

                    final tabAssignmentBadge = Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.scaffoldBackground,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: assignedTab != null
                              ? scheme.accentColor.withAlpha(120)
                              : scheme.borderColor,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: assignedTab?.id,
                          hint: Text(
                            'Assign Tab',
                            style: TextStyle(fontSize: 11, color: scheme.mutedText),
                          ),
                          isDense: true,
                          dropdownColor: scheme.elevatedSurface,
                          items: [
                            DropdownMenuItem<String?>(
                              value: null,
                              child: Text(
                                'Unassigned',
                                style: TextStyle(fontSize: 11, color: scheme.mutedText),
                              ),
                            ),
                            ...widget.availableTabs.map((tab) {
                              return DropdownMenuItem<String?>(
                                value: tab.id,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      tab.type == 'sftp'
                                          ? Icons.folder_shared
                                          : Icons.terminal,
                                      size: 13,
                                      color: scheme.accentColor,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      tab.title,
                                      style: TextStyle(fontSize: 11, color: scheme.primaryText),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                          onChanged: (tabId) {
                            widget.onAssignTaskToTab(task, tabId);
                          },
                        ),
                      ),
                    );

                    final isCollapsed = _collapsedTaskIds.contains(task.id);
                    final isAddingSubtask = _addingSubtaskForIds.contains(task.id);
                    final totalSubtasks = task.subtasks.length;
                    final completedSubtasks = task.completedSubtaskCount;

                    final subtaskProgressBadge = totalSubtasks > 0
                        ? InkWell(
                            onTap: () {
                              setState(() {
                                if (isCollapsed) {
                                  _collapsedTaskIds.remove(task.id);
                                } else {
                                  _collapsedTaskIds.add(task.id);
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: completedSubtasks == totalSubtasks
                                    ? Colors.greenAccent.withAlpha(30)
                                    : scheme.scaffoldBackground,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: completedSubtasks == totalSubtasks
                                      ? Colors.greenAccent.withAlpha(140)
                                      : scheme.borderColor,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.checklist,
                                    size: 13,
                                    color: completedSubtasks == totalSubtasks
                                        ? Colors.greenAccent
                                        : scheme.accentColor,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$completedSubtasks/$totalSubtasks',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: completedSubtasks == totalSubtasks
                                          ? Colors.greenAccent
                                          : scheme.primaryText,
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  Icon(
                                    isCollapsed ? Icons.expand_more : Icons.expand_less,
                                    size: 14,
                                    color: scheme.mutedText,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : null;

                    final addSubtaskButton = IconButton(
                      icon: Icon(
                        Icons.playlist_add,
                        size: 18,
                        color: isAddingSubtask ? scheme.accentColor : scheme.mutedText,
                      ),
                      tooltip: 'Add Subtask',
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        setState(() {
                          if (isAddingSubtask) {
                            _addingSubtaskForIds.remove(task.id);
                          } else {
                            _addingSubtaskForIds.add(task.id);
                            _collapsedTaskIds.remove(task.id);
                          }
                        });
                      },
                    );

                    final subtasksSection = (!isCollapsed && (totalSubtasks > 0 || isAddingSubtask))
                        ? Container(
                            margin: const EdgeInsets.only(left: 34, top: 8, right: 4, bottom: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: scheme.scaffoldBackground.withAlpha(160),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: scheme.borderColor.withAlpha(150)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ...task.subtasks.map((sub) {
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: Checkbox(
                                            value: sub.isCompleted,
                                            visualDensity: VisualDensity.compact,
                                            onChanged: (_) => _toggleSubtask(task, sub),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: GestureDetector(
                                            onTap: () => _toggleSubtask(task, sub),
                                            child: Text(
                                              sub.title,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: sub.isCompleted
                                                    ? scheme.mutedText
                                                    : scheme.primaryText,
                                                decoration: sub.isCompleted
                                                    ? TextDecoration.lineThrough
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.edit_outlined,
                                            size: 14,
                                            color: scheme.mutedText,
                                          ),
                                          tooltip: 'Edit Subtask',
                                          constraints: const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 24,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onPressed: () => _editSubtaskDialog(task, sub),
                                        ),
                                        const SizedBox(width: 2),
                                        IconButton(
                                          icon: Icon(
                                            Icons.close,
                                            size: 14,
                                            color: scheme.mutedText,
                                          ),
                                          tooltip: 'Delete Subtask',
                                          constraints: const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 24,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onPressed: () => _deleteSubtask(task, sub),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                                if (isAddingSubtask) ...[
                                  if (totalSubtasks > 0) const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.subdirectory_arrow_right,
                                        size: 15,
                                        color: scheme.accentColor,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: TextField(
                                          controller: _getSubtaskController(task.id),
                                          autofocus: true,
                                          style: const TextStyle(fontSize: 12),
                                          decoration: const InputDecoration(
                                            hintText: 'Add a subtask and press Enter...',
                                            isDense: true,
                                            contentPadding: EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 8,
                                            ),
                                            border: OutlineInputBorder(),
                                          ),
                                          onSubmitted: (_) => _addSubtaskToTask(task),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      OutlinedButton.icon(
                                        icon: const Icon(Icons.add, size: 14),
                                        label: const Text(
                                          'Add',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                        ),
                                        onPressed: () => _addSubtaskToTask(task),
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        icon: Icon(
                                          Icons.close,
                                          size: 15,
                                          color: scheme.mutedText,
                                        ),
                                        tooltip: 'Close subtask input',
                                        constraints: const BoxConstraints(
                                          minWidth: 24,
                                          minHeight: 24,
                                        ),
                                        padding: EdgeInsets.zero,
                                        onPressed: () {
                                          setState(() {
                                            _addingSubtaskForIds.remove(task.id);
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          )
                        : null;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: scheme.panelBackground,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isOverdue
                              ? Colors.redAccent.withAlpha(160)
                              : scheme.borderColor,
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 580) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Tooltip(
                                      message: 'Mark done (immediately removes task)',
                                      child: Checkbox(
                                        value: false,
                                        onChanged: (_) => widget.onCompleteTask(task.id),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        task.title,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: scheme.primaryText,
                                        ),
                                      ),
                                    ),
                                    addSubtaskButton,
                                    IconButton(
                                      icon: Icon(Icons.edit_outlined, size: 16, color: scheme.mutedText),
                                      tooltip: 'Edit Task',
                                      onPressed: () => _showEditTaskDialog(task),
                                    ),
                                  ],
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 12, top: 4),
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      importanceBadge,
                                      ?subtaskProgressBadge,
                                      dueDateBadge,
                                      tabAssignmentBadge,
                                    ],
                                  ),
                                ),
                                ?subtasksSection,
                              ],
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Tooltip(
                                    message: 'Mark done (immediately removes task)',
                                    child: Checkbox(
                                      value: false,
                                      onChanged: (_) => widget.onCompleteTask(task.id),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  importanceBadge,
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      task.title,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: scheme.primaryText,
                                      ),
                                    ),
                                  ),
                                  if (subtaskProgressBadge != null) ...[
                                    subtaskProgressBadge,
                                    const SizedBox(width: 8),
                                  ],
                                  dueDateBadge,
                                  const SizedBox(width: 10),
                                  tabAssignmentBadge,
                                  const SizedBox(width: 6),
                                  addSubtaskButton,
                                  IconButton(
                                    icon: Icon(Icons.edit_outlined, size: 16, color: scheme.mutedText),
                                    tooltip: 'Edit Task',
                                    onPressed: () => _showEditTaskDialog(task),
                                  ),
                                ],
                              ),
                              ?subtasksSection,
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
