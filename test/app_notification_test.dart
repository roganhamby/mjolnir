import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mjolnir/ui/app_notification.dart';
import 'package:mjolnir/theme/app_color_schemes.dart';

void main() {
  Widget buildTestApp({required Widget child}) {
    return MaterialApp(
      navigatorKey: AppNotification.navigatorKey,
      theme: AppColorSchemes.mjolnirAmber.toThemeData(),
      home: Scaffold(
        body: child,
      ),
    );
  }

  setUp(() {
    AppNotification.dismissAll();
  });

  testWidgets('AppNotification.show displays message in floating notification box', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              AppNotification.show(
                context,
                message: 'Screen logging started: session.log',
              );
            },
            child: const Text('Trigger Notification'),
          ),
        ),
      ),
    );

    // Initial state: no notification visible
    expect(find.text('Screen logging started: session.log'), findsNothing);

    // Tap button to trigger notification
    await tester.tap(find.text('Trigger Notification'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Notification is now visible
    expect(find.text('Screen logging started: session.log'), findsOneWidget);

    // Notification is positioned in the top-right
    final notifFinder = find.text('Screen logging started: session.log');
    final notifTopLeft = tester.getTopLeft(notifFinder);
    expect(notifTopLeft.dy, greaterThanOrEqualTo(64.0));
    expect(notifTopLeft.dx, greaterThan(400.0)); // Over to the right of standard screen

    // Closes manually when 'x' close button is tapped
    final closeFinder = find.byIcon(Icons.close);
    expect(closeFinder, findsOneWidget);
    await tester.tap(closeFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Screen logging started: session.log'), findsNothing);
  });

  testWidgets('AppNotification supports action buttons and triggers callback', (tester) async {
    bool actionExecuted = false;

    await tester.pumpWidget(
      buildTestApp(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              AppNotification.show(
                context,
                message: 'Screen log saved: test.log',
                actionLabel: 'Show in Finder',
                onAction: () {
                  actionExecuted = true;
                },
              );
            },
            child: const Text('Show Action Notification'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show Action Notification'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Screen log saved: test.log'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);

    // Tap action button
    await tester.tap(find.text('Show in Finder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(actionExecuted, isTrue);
    expect(find.text('Screen log saved: test.log'), findsNothing);
  });

  testWidgets('AppNotification auto-dismisses after duration', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              AppNotification.show(
                context,
                message: 'Auto dismissing message',
                duration: const Duration(seconds: 1),
              );
            },
            child: const Text('Show Auto Notification'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show Auto Notification'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Auto dismissing message'), findsOneWidget);

    // Fast-forward past duration
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Auto dismissing message'), findsNothing);
  });

  testWidgets('AppNotification handles success and error styling helpers', (tester) async {
    await tester.pumpWidget(
      buildTestApp(
        child: Builder(
          builder: (context) => Column(
            children: [
              ElevatedButton(
                onPressed: () => AppNotification.success(context, 'Success transfer'),
                child: const Text('Trigger Success'),
              ),
              ElevatedButton(
                onPressed: () => AppNotification.error(context, 'Failed transfer'),
                child: const Text('Trigger Error'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Trigger Success'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Success transfer'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

    await tester.tap(find.text('Trigger Error'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Failed transfer'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
