import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TestTab {
  final String id;
  final String title;
  TestTab({required this.id, required this.title});
}

void main() {
  testWidgets('Horizontal ReorderableListView rearranges tabs and preserves active selection', (tester) async {
    final tabs = [
      TestTab(id: 'tab-1', title: 'SSH: Server Alpha'),
      TestTab(id: 'tab-2', title: 'SFTP: Storage Beta'),
      TestTab(id: 'tab-3', title: 'Tasks'),
    ];
    int activeTabIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SizedBox(
                height: 38,
                child: ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  itemCount: tabs.length,
                  onReorder: (int oldIndex, int newIndex) {
                    setState(() {
                      if (oldIndex < newIndex) {
                        newIndex -= 1;
                      }
                      final activeTabId = (activeTabIndex >= 0 && activeTabIndex < tabs.length)
                          ? tabs[activeTabIndex].id
                          : null;
                      final movedTab = tabs.removeAt(oldIndex);
                      tabs.insert(newIndex, movedTab);
                      if (activeTabId != null) {
                        activeTabIndex = tabs.indexWhere((t) => t.id == activeTabId);
                      }
                    });
                  },
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    final isActive = index == activeTabIndex;

                    return Container(
                      key: ValueKey(tab.id),
                      height: 38,
                      color: isActive ? Colors.blueGrey : Colors.black87,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: Listener(
                              onPointerDown: (e) {
                                if (e.buttons == kPrimaryMouseButton) {
                                  if (activeTabIndex != index) {
                                    setState(() {
                                      activeTabIndex = index;
                                    });
                                  }
                                }
                              },
                              child: GestureDetector(
                                onTap: () {
                                  if (activeTabIndex != index) {
                                    setState(() {
                                      activeTabIndex = index;
                                    });
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Text(tab.title),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 14),
                            onPressed: () {
                              setState(() {
                                tabs.removeAt(index);
                                if (tabs.isEmpty) {
                                  activeTabIndex = -1;
                                } else if (index < activeTabIndex) {
                                  activeTabIndex -= 1;
                                } else if (activeTabIndex >= tabs.length) {
                                  activeTabIndex = tabs.length - 1;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );

    // Initial check
    expect(tabs[0].id, 'tab-1');
    expect(tabs[1].id, 'tab-2');
    expect(tabs[2].id, 'tab-3');
    expect(activeTabIndex, 0);

    // Tap on tab-2 to select it
    await tester.tap(find.text('SFTP: Storage Beta'));
    await tester.pumpAndSettle();
    expect(activeTabIndex, 1);

    // Drag tab-1 to the right past tab-2
    await tester.drag(find.byType(ReorderableDragStartListener).first, const Offset(250, 0));
    await tester.pumpAndSettle();

    // Verify tabs reordered: tab-2 is now index 0, tab-1 is index 1
    expect(tabs[0].id, 'tab-2');
    expect(tabs[1].id, 'tab-1');
    expect(tabs[2].id, 'tab-3');

    // Active tab (which was activated upon clicking and dragging tab-1) followed tab-1 to index 1
    expect(activeTabIndex, 1);
    expect(tabs[activeTabIndex].id, 'tab-1');

    // Now drag the last tab ('Tasks', currently index 2) to the front
    final thirdTabLocation = tester.getCenter(find.text('Tasks'));
    final frontTabLocation = tester.getCenter(find.text('SFTP: Storage Beta'));
    await tester.drag(find.text('Tasks'), Offset(frontTabLocation.dx - thirdTabLocation.dx - 20, 0));
    await tester.pumpAndSettle();

    expect(tabs[0].id, 'tab-3');
    expect(tabs[1].id, 'tab-2');
    expect(tabs[2].id, 'tab-1');
    // activeTab was tab-3 which moved to index 0
    expect(activeTabIndex, 0);
    expect(tabs[activeTabIndex].id, 'tab-3');

    // Select middle tab ('tab-2', index 1) and close the left tab ('tab-3', index 0)
    await tester.tap(find.text('SFTP: Storage Beta'));
    await tester.pumpAndSettle();
    expect(activeTabIndex, 1);
    expect(tabs[activeTabIndex].id, 'tab-2');

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    // Verify active selection stays on 'tab-2' (now at index 0) instead of jumping to 'tab-1'
    expect(tabs.length, 2);
    expect(tabs[0].id, 'tab-2');
    expect(tabs[1].id, 'tab-1');
    expect(activeTabIndex, 0);
    expect(tabs[activeTabIndex].id, 'tab-2');
  });
}
