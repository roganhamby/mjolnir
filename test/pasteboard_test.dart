import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/models/stored_string_item.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';

void main() {
  testWidgets('Pasteboard context menu copies string to clipboard', (tester) async {
    String? copiedText;

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          final args = methodCall.arguments as Map<dynamic, dynamic>;
          copiedText = args['text'] as String?;
          return null;
        }
        return null;
      },
    );

    final items = [
      StoredStringItem(
        id: 'str-1',
        label: 'Production DB Token',
        value: 'postgres://admin:secret@db.prod.internal:5432/main',
      ),
      StoredStringItem(
        id: 'str-2',
        label: '',
        value: 'curl -s https://example.com/status',
      ),
    ];

    bool tabOpened = false;

    Widget buildTestWidget() {
      return MaterialApp(
        theme: AppColorSchemes.mjolnirAmber.toThemeData(),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              Builder(
                builder: (context) {
                  final scheme = AppColorScheme.of(context);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapUp: (details) async {
                      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
                      final pos = details.globalPosition;
                      final menuItems = <PopupMenuEntry<String>>[];

                      for (final item in items) {
                        menuItems.add(
                          PopupMenuItem<String>(
                            value: item.id,
                            child: Text(item.label.isNotEmpty ? item.label : item.value),
                          ),
                        );
                      }
                      menuItems.add(const PopupMenuDivider());
                      menuItems.add(
                        const PopupMenuItem<String>(
                          value: '__open_pasteboard_tab__',
                          child: Text('Open Pasteboard Tab'),
                        ),
                      );

                      final selectedId = await showMenu<String>(
                        context: context,
                        position: RelativeRect.fromRect(
                          pos & const Size(40, 40),
                          Offset.zero & overlay.size,
                        ),
                        items: menuItems,
                      );

                      if (selectedId == null) return;
                      if (selectedId == '__open_pasteboard_tab__') {
                        tabOpened = true;
                        return;
                      }

                      final selected = items.firstWhere((s) => s.id == selectedId);
                      await Clipboard.setData(ClipboardData(text: selected.value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Copied "${selected.label}" to clipboard.')),
                      );
                    },
                    child: TextButton.icon(
                      icon: Icon(Icons.content_paste, size: 18, color: scheme.accentColor),
                      label: Text('Pasteboard (${items.length})'),
                      onPressed: () {
                        tabOpened = true;
                      },
                    ),
                  );
                },
              ),
            ],
          ),
          body: const SizedBox(),
        ),
      );
    }

    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    final btnFinder = find.text('Pasteboard (2)');
    expect(btnFinder, findsOneWidget);

    // Right click
    final gesture = await tester.startGesture(
      tester.getCenter(btnFinder),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Production DB Token'), findsOneWidget);
    expect(find.text('Open Pasteboard Tab'), findsOneWidget);

    // Click item to copy
    await tester.tap(find.text('Production DB Token'));
    await tester.pumpAndSettle();

    expect(copiedText, equals('postgres://admin:secret@db.prod.internal:5432/main'));
    expect(find.text('Copied "Production DB Token" to clipboard.'), findsOneWidget);

    // Left click opens tab
    await tester.tap(btnFinder);
    await tester.pumpAndSettle();
    expect(tabOpened, isTrue);
  });

  testWidgets('Pasteboard empty state shows "Pasteboard" and empty notice in context menu', (tester) async {
    final items = <StoredStringItem>[];
    bool tabOpened = false;

    Widget buildTestWidget() {
      return MaterialApp(
        theme: AppColorSchemes.mjolnirAmber.toThemeData(),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              Builder(
                builder: (context) {
                  final scheme = AppColorScheme.of(context);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onSecondaryTapUp: (details) async {
                      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
                      final pos = details.globalPosition;
                      final menuItems = <PopupMenuEntry<String>>[];

                      if (items.isEmpty) {
                        menuItems.add(
                          const PopupMenuItem<String>(
                            enabled: false,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.info_outline, size: 16),
                                SizedBox(width: 8),
                                Text('Pasteboard is empty'),
                              ],
                            ),
                          ),
                        );
                      }
                      menuItems.add(const PopupMenuDivider());
                      menuItems.add(
                        const PopupMenuItem<String>(
                          value: '__open_pasteboard_tab__',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.tab, size: 16),
                              SizedBox(width: 8),
                              Text('Open Pasteboard Tab'),
                            ],
                          ),
                        ),
                      );

                      final selectedId = await showMenu<String>(
                        context: context,
                        position: RelativeRect.fromRect(
                          pos & const Size(40, 40),
                          Offset.zero & overlay.size,
                        ),
                        items: menuItems,
                        constraints: const BoxConstraints(minWidth: 220, maxWidth: 360, maxHeight: 420),
                      );

                      if (selectedId == '__open_pasteboard_tab__') {
                        tabOpened = true;
                      }
                    },
                    child: TextButton.icon(
                      icon: Icon(Icons.content_paste, size: 18, color: scheme.accentColor),
                      label: Text(
                        items.isEmpty ? 'Pasteboard' : 'Pasteboard (${items.length})',
                      ),
                      onPressed: () {
                        tabOpened = true;
                      },
                    ),
                  );
                },
              ),
            ],
          ),
          body: const SizedBox(),
        ),
      );
    }

    await tester.pumpWidget(buildTestWidget());
    await tester.pumpAndSettle();

    final btnFinder = find.text('Pasteboard');
    expect(btnFinder, findsOneWidget);

    // Right click
    final gesture = await tester.startGesture(
      tester.getCenter(btnFinder),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Pasteboard is empty'), findsOneWidget);
    expect(find.text('Open Pasteboard Tab'), findsOneWidget);

    await tester.tap(find.text('Open Pasteboard Tab'));
    await tester.pumpAndSettle();
    expect(tabOpened, isTrue);
  });
}
