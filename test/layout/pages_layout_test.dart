// Every section of the app at phone, tablet and desktop widths: fails on any
// overflow ("A RenderFlex overflowed by 12 pixels") and, with
// `--update-goldens`, writes a screenshot of each one to goldens/ (ignored by
// git) to look through.
//
//   flutter test test/layout                    # check layouts
//   flutter test test/layout --update-goldens   # also write the screenshots
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/screens/dashboard_shell.dart';
import 'package:velora_club/src/theme.dart';

import 'harness.dart';

const sizes = {
  'phone360': Size(360, 780),
  'phone412': Size(412, 915),
  'tablet800': Size(800, 1280),
  'desktop1280': Size(1280, 800),
};

const pages = [
  'club',
  'sales',
  'reservations',
  'waitlist',
  'customers',
  'orders',
  'shift',
  'products',
  'expenses',
  'reports',
  'relay',
  'staff',
  'settings',
];

void main() {
  setUpAll(setUpLayoutTests);

  for (final size in sizes.entries) {
    for (final (index, page) in pages.indexed) {
      testWidgets('$page @ ${size.key}', (tester) async {
        tester.view.physicalSize = size.value * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);

        final errors = LayoutErrors()..start();
        final controller = fakeController(page: index);
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
          // Screens show live timers, so the screenshots are for eyeballing only

          // (written with --update-goldens), never compared.

          if (autoUpdateGoldenFiles) {
            await expectLater(
                find.byType(DashboardShell),
                matchesGoldenFile(
                    'goldens/${size.key}/${index.toString().padLeft(2, '0')}_$page.png'));
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
                '$page @ ${size.key}\n${errors.errors.toSet().map((e) => '  $e').join('\n')}\n',
                mode: FileMode.append);
        }
        expect(errors.errors, isEmpty,
            reason: errors.errors.toSet().join('\n'));
      });
    }
  }
}
