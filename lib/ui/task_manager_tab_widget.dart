import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../models/task_item.dart';

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

  const AssignedTabTaskBanner({
    super.key,
    required this.task,
    required this.onCompleteTask,
    required this.onUnassignTask,
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

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final isOverdue = task.isOverdue;
    final dueDateStr = task.dueDate != null
        ? DateFormat('MMM d, HH:mm').format(task.dueDate!.toLocal())
        : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isOverdue
            ? Colors.redAccent.withAlpha(35)
            : const Color(0xFF323233),
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
                color: isOverdue ? Colors.redAccent : Colors.grey.shade400,
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
                  color: isOverdue ? Colors.redAccent.shade100 : Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (dueDateStr != null) ...[
            const SizedBox(width: 8),
            Icon(
              isOverdue ? Icons.warning_amber_rounded : Icons.schedule,
              size: 12,
              color: isOverdue ? Colors.redAccent : Colors.grey.shade400,
            ),
            const SizedBox(width: 3),
            Text(
              dueDateStr,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isOverdue ? FontWeight.bold : FontWeight.normal,
                color: isOverdue ? Colors.redAccent : Colors.grey.shade300,
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
                  color: Colors.grey.shade400,
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
    super.dispose();
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
    TaskImportance selectedImportance = task.importance;
    DateTime? selectedDueDate = task.dueDate;
    String? selectedTabId = widget.availableTabs.any((t) => t.id == task.assignedTabId)
        ? task.assignedTabId
        : null;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isOverdue = selectedDueDate != null &&
              DateTime.now().isAfter(selectedDueDate!.toLocal());

          return AlertDialog(
            title: const Text('Edit Task'),
            content: SizedBox(
              width: 440,
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
                ],
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
                  task.title = newTitle;
                  task.importance = selectedImportance;
                  task.dueDate = selectedDueDate;
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
          decoration: const BoxDecoration(
            color: Color(0xFF252526),
            border: Border(bottom: BorderSide(color: Color(0xFF333333))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.task_alt, color: Colors.amberAccent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Task Manager (${widget.tasks.length} Active)',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  const Text('Sort by: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 4),
                  DropdownButton<String>(
                    value: _sortBy,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                    dropdownColor: const Color(0xFF2D2D2D),
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
                      border: Border.all(color: Colors.grey.shade700),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<TaskImportance>(
                        value: _newTaskImportance,
                        isDense: true,
                        dropdownColor: const Color(0xFF2D2D2D),
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
                      color: isNewTaskOverdue ? Colors.redAccent : Colors.amberAccent,
                    ),
                    label: Text(
                      _newTaskDueDate != null
                          ? DateFormat('MMM d, yyyy HH:mm').format(_newTaskDueDate!.toLocal())
                          : 'Due Date & Time',
                      style: TextStyle(
                        fontSize: 12,
                        color: isNewTaskOverdue ? Colors.redAccent : Colors.white,
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
                      border: Border.all(color: Colors.grey.shade700),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: validNewTaskTabId,
                        hint: const Text('Assign to Tab', style: TextStyle(fontSize: 12)),
                        isDense: true,
                        dropdownColor: const Color(0xFF2D2D2D),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Unassigned', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                                    color: Colors.amberAccent,
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
                      Icon(Icons.check_circle_outline, size: 52, color: Colors.grey.shade600),
                      const SizedBox(height: 12),
                      const Text(
                        'No active tasks. Add a task above and optionally assign it to an SSH or SFTP tab.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: sortedTasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final task = sortedTasks[index];
                    final isOverdue = task.isOverdue;
                    final assignedTab = widget.availableTabs
                        .where((t) => t.id == task.assignedTabId)
                        .firstOrNull;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF252526),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isOverdue
                              ? Colors.redAccent.withAlpha(160)
                              : const Color(0xFF383838),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Immediate completion checkbox
                          Tooltip(
                            message: 'Mark done (immediately removes task)',
                            child: Checkbox(
                              value: false,
                              onChanged: (_) => widget.onCompleteTask(task.id),
                            ),
                          ),
                          const SizedBox(width: 6),

                          // Importance Dropdown Badge
                          Container(
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
                                dropdownColor: const Color(0xFF2D2D2D),
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
                          ),
                          const SizedBox(width: 12),

                          // Task Title
                          Expanded(
                            child: Text(
                              task.title,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white,
                              ),
                            ),
                          ),

                          // Due Date Badge (turns red when passed)
                          InkWell(
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
                                    : const Color(0xFF1E1E1E),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isOverdue
                                      ? Colors.redAccent
                                      : Colors.grey.shade800,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isOverdue ? Icons.error_outline : Icons.schedule,
                                    size: 14,
                                    color: isOverdue ? Colors.redAccent : Colors.grey.shade400,
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
                                          : (task.dueDate != null ? Colors.grey.shade200 : Colors.grey),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),

                          // Tab Assignment Dropdown
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: assignedTab != null
                                    ? Colors.amberAccent.withAlpha(120)
                                    : Colors.grey.shade800,
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String?>(
                                value: assignedTab?.id,
                                hint: const Text(
                                  'Assign Tab',
                                  style: TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                                isDense: true,
                                dropdownColor: const Color(0xFF2D2D2D),
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text(
                                      'Unassigned',
                                      style: TextStyle(fontSize: 11, color: Colors.grey),
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
                                            color: Colors.amberAccent,
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            tab.title,
                                            style: const TextStyle(fontSize: 11, color: Colors.white),
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
                          ),
                          const SizedBox(width: 6),

                          // Edit button
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 16, color: Colors.grey),
                            tooltip: 'Edit Task',
                            onPressed: () => _showEditTaskDialog(task),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
