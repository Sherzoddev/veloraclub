// Bookings on the table cards and on the bookings page.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/screens/dashboard_shell.dart';
import 'package:velora_club/src/theme.dart';
import 'package:velora_club/src/utils.dart';

import 'layout/harness.dart';

Map<String, dynamic> booking(String status,
        {Duration starts = const Duration(hours: 1),
        Duration length = const Duration(hours: 1)}) =>
    {
      'status': status,
      'starts_at': DateTime.now().toUtc().add(starts).toIso8601String(),
      'ends_at': DateTime.now().toUtc().add(starts + length).toIso8601String(),
    };

void main() {
  group('bookingIsOpen', () {
    test('waiting and confirmed bookings count', () {
      expect(bookingIsOpen(booking('pending')), isTrue);
      expect(bookingIsOpen(booking('confirmed')), isTrue);
    });

    test('a client who has come, a finished or a cancelled one does not', () {
      for (final status in ['arrived', 'completed', 'cancelled', 'no_show']) {
        expect(bookingIsOpen(booking(status)), isFalse, reason: status);
      }
    });

    test('one that is under way still counts, one long over does not', () {
      expect(
          bookingIsOpen(booking('pending',
              starts: const Duration(minutes: -20),
              length: const Duration(hours: 1))),
          isTrue);
      expect(
          bookingIsOpen(booking('pending',
              starts: const Duration(hours: -5),
              length: const Duration(hours: 1))),
          isFalse);
    });

    test('one that ended a few minutes ago is kept for a while', () {
      expect(
          bookingIsOpen(booking('confirmed',
              starts: const Duration(minutes: -70),
              length: const Duration(hours: 1))),
          isTrue);
    });
  });

  group('bookings page', () {
    setUpAll(setUpLayoutTests);

    testWidgets('shows the open ones, and every kind after "Barchasi"',
        (tester) async {
      tester.view.physicalSize = const Size(2560, 4800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      final errors = LayoutErrors()..start();
      final controller = fakeController(page: 2);
      try {
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: ListenableBuilder(
            listenable: controller,
            builder: (_, __) => DashboardShell(controller: controller),
          ),
        ));
        await settle(tester);
        // The test data holds waiting, confirmed, started and cancelled ones.
        expect(find.text('PENDING'), findsWidgets);
        expect(find.text('CONFIRMED'), findsWidgets);
        expect(find.text('ARRIVED'), findsNothing);
        expect(find.text('CANCELLED'), findsNothing);

        await tester.tap(find.text('Barchasi'));
        await settle(tester);
        expect(find.text('ARRIVED'), findsWidgets);
        expect(find.text('CANCELLED'), findsWidgets);

        await tester.tap(find.text('Dolzarb'));
        await settle(tester);
        expect(find.text('ARRIVED'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        errors.stop();
      }
    });
  });

  group('table cards', () {
    setUpAll(setUpLayoutTests);

    testWidgets(
        'a free table shows its confirmed booking; a started one does not',
        (tester) async {
      tester.view.physicalSize = const Size(2560, 4800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      final errors = LayoutErrors()..start();
      final controller = fakeController(page: 0);
      try {
        await tester.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          home: ListenableBuilder(
            listenable: controller,
            builder: (_, __) => DashboardShell(controller: controller),
          ),
        ));
        await settle(tester);
        // The test data: tables 1-5 are being played, 6 has a confirmed
        // booking, 7 one whose client has come, 8 a cancelled one.
        expect(find.textContaining('Bron '),
            findsOneWidget); // "Bronlar" in the menu is not a booking
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        errors.stop();
      }
    });
  });
}
