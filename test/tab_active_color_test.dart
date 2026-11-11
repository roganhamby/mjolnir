import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/main.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';

void main() {
  testWidgets('Tab highlight color is removed when tab is clicked off', (tester) async {
    final tabs = [
      TabItem(
        id: 'term-1',
        title: 'Server 1 (SSH)',
        icon: Icons.terminal,
        type: 'ssh',
      ),
      TabItem(
        id: 'notes-1',
        title: 'Notes',
        icon: Icons.sticky_note_2_outlined,
        color: Colors.lightBlueAccent,
        type: 'notes',
      ),
    ];
    int activeTabIndex = 1; // Start with Notes tab active

    final scheme = AppColorSchemes.mjolnirAmber;

    await tester.pumpWidget(
      MaterialApp(
        theme: scheme.toThemeData(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SizedBox(
                height: 38,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: tabs.length,
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    final isActive = index == activeTabIndex;
                    final tabHighlightColor = isActive
                        ? (tab.color ?? scheme.accentColor)
                        : Colors.transparent;

                    return Container(
                      key: ValueKey(tab.id),
                      height: 38,
                      decoration: BoxDecoration(
                        color: isActive ? scheme.panelBackground : scheme.scaffoldBackground,
                        border: Border(
                          top: BorderSide(
                            color: tabHighlightColor,
                            width: tab.color != null ? 3 : 2,
                          ),
                          right: BorderSide(color: scheme.borderColor),
                        ),
                      ),
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            activeTabIndex = index;
                          });
                        },
                        child: Text(tab.title),
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

    // Helper to get top border color of a tab container
    Color getTopBorderColor(String tabId) {
      final container = tester.widget<Container>(find.byKey(ValueKey(tabId)));
      final decoration = container.decoration as BoxDecoration;
      final border = decoration.border as Border;
      return border.top.color;
    }

    // Initially: Notes tab is active (index 1), Server 1 is inactive (index 0)
    expect(getTopBorderColor('notes-1'), Colors.lightBlueAccent);
    expect(getTopBorderColor('term-1'), Colors.transparent);

    // Click off Notes tab to Server 1 (index 0)
    await tester.tap(find.text('Server 1 (SSH)'));
    await tester.pumpAndSettle();

    // Now: Notes tab has its highlight color removed (transparent)
    expect(getTopBorderColor('notes-1'), Colors.transparent);
    // Server 1 is active, so it has the scheme accent color
    expect(getTopBorderColor('term-1'), scheme.accentColor);
  });
}
