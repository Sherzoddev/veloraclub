// Dialogs opened from the pages, on the narrowest phone and on desktop:
// same overflow check and screenshots as pages_layout_test.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/screens/dashboard_shell.dart';
import 'package:velora_club/src/theme.dart';

import 'harness.dart';

const sizes = {
  'phone360': Size(360, 780),
  'desktop1280': Size(1280, 800),
};

/// name -> (page index, finder of the widget to tap, optional second tap).
final dialogs = <String, (int, Finder Function(), Finder Function()?)>{
  'product_categories': (7, () => find.byIcon(Icons.category_outlined), null),
  'product_category_new': (
    7,
    () => find.byIcon(Icons.category_outlined),
    () => find.widgetWithIcon(FilledButton, Icons.add_rounded).last,
  ),
  'product_edit': (7, () => find.text('Tovar qo\'shish'), null),
  'expense_new': (8, () => find.byIcon(Icons.add_rounded).first, null),
  'customer_new': (4, () => find.byIcon(Icons.person_add_alt_1_rounded), null),
  for (final tab in ['Tariflar', 'Chek', 'Telegram-bot', 'Rele', 'Token'])
    'settings_$tab': (12, () => find.text(tab).last, null),
};

void main() {
  setUpAll(setUpLayoutTests);

  for (final size in sizes.entries) {
    for (final entry in dialogs.entries) {
      final (page, first, second) = entry.value;
      testWidgets('${entry.key} @ ${size.key}', (tester) async {
        tester.view.physicalSize = size.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        final errors = LayoutErrors()..start();
        final controller = fakeController(page: page);
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
          final target = first();
          if (target.evaluate().isEmpty) {
            markTestSkipped('no button for ${entry.key}');
            return;
          }
          await tester.ensureVisible(target.first);
          await tester.tap(target.first, warnIfMissed: false);
          await settle(tester);
          if (second != null) {
            await tester.tap(second(), warnIfMissed: false);
            await settle(tester);
          }
          // Screens show live timers, so the screenshots are for eyeballing only

          // (written with --update-goldens), never compared.

          if (autoUpdateGoldenFiles) {
            await expectLater(
                find.byType(MaterialApp),
                matchesGoldenFile(
                    'goldens/dialogs/${size.key}_${entry.key}.png'));
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          errors.stop();
        }
        if (errors.errors.isNotEmpty) {
          File('build/layout_report.txt')
            ..createSync(recursive: true)
            ..writeAsStringSync(
                '${entry.key} @ ${size.key}\n${errors.errors.toSet().map((e) => '  $e').join('\n')}\n',
                mode: FileMode.append);
        }
        expect(errors.errors, isEmpty,
            reason: errors.errors.toSet().join('\n'));
      });
    }
  }
}
