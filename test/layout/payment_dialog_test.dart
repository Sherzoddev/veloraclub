// The payment sheet ("Yakunlash va to'lash"): single method as before, and
// the mixed payment (cash + card + transfer on one check). Runs against the
// fake backend; the create_payment call is recorded to see exactly what would
// be sent to the server. Also checks for overflows at phone and desktop size.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:velora_club/src/data/club_repository.dart';
import 'package:velora_club/src/screens/session_payment_dialog.dart';
import 'package:velora_club/src/state/club_controller.dart';
import 'package:velora_club/src/theme.dart';

import 'fake_backend.dart' as fake;
import 'harness.dart';

const sizes = {
  'phone360': Size(360, 780),
  'desktop1280': Size(1280, 800),
};

final cashId = fake.paymentMethods[0]['id'];
final cardId = fake.paymentMethods[1]['id']; // Uzcard
final transferId = fake.paymentMethods[5]['id'];

/// The fake backend, except for what this sheet reads or writes: a check of
/// 100 000 (60 000 time + 40 000 bar), and create_payment is recorded.
class Setup {
  Setup({this.completes = true}) {
    final inner = fake.fakeSupabaseHttp();
    final client = SupabaseClient(
      'https://test.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        final path = request.url.path;
        Response json(Object body) => Response(jsonEncode(body), 200,
            request: request,
            headers: {'content-type': 'application/json; charset=utf-8'});
        if (path.endsWith('/rpc/app_order_json')) {
          return json({
            'id': 'o1',
            'order_number': 7,
            'status': 'OPEN',
            'total_amount': 100000,
            'time_amount': 60000,
            'items_amount': 40000,
            'discount_amount': 0,
            'customer_id': null,
            'order_items': [
              {
                'kind': 'PRODUCT',
                'description': 'Cola',
                'quantity': 2,
                'total_price': 40000,
                'unit_cost': 8000
              }
            ],
          });
        }
        if (path.endsWith('/rpc/create_payment')) {
          calls.add(jsonDecode(request.body) as Map<String, dynamic>);
          return json({
            'order': {
              'order': completes
                  ? {'status': 'COMPLETED'}
                  : {
                      'status': 'OPEN',
                      'total_amount': 100000,
                      'paid_amount': 70000
                    }
            },
            'payments': [],
          });
        }
        // The request handed to us is already finalized: send a copy on.
        final copy = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return Response.fromStream(await inner.send(copy));
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final role = fake.roles.firstWhere((r) => r['key'] == 'owner');
    controller = ClubController(ClubRepository(client))
      ..context = ClubContextData(
        club: fake.club,
        member: {...fake.member, 'roles': role},
        role: role,
        profile: fake.profile,
      )
      ..loading = false;
  }

  final bool completes;
  final List<Map<String, dynamic>> calls = [];
  late final ClubController controller;
}

typedef Response = http.Response;

Future<void> open(WidgetTester tester, Setup setup, Size size) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showSessionPaymentDialog(context,
                controller: setup.controller,
                orderId: 'o1',
                resourceName: '1 Stol'),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await settle(tester);
}

Finder field(String label) => find.widgetWithText(TextField, label);

Future<void> type(WidgetTester tester, String label, String text) async {
  await tester.ensureVisible(field(label));
  await tester.enterText(field(label), text);
  await tester.pump();
}

Finder payButton() =>
    find.widgetWithText(FilledButton, 'To\'lash — 100 000 so\'m');

void main() {
  setUpAll(setUpLayoutTests);

  for (final size in sizes.entries) {
    testWidgets('mixed payment: cash + card, sent as two lines @ ${size.key}',
        (tester) async {
      final errors = LayoutErrors()..start();
      final setup = Setup();
      await open(tester, setup, size.value);
      expect(find.text('Aralash to\'lov'), findsOneWidget);

      await tester.tap(find.text('Aralash to\'lov'));
      await tester.pump();
      // A field for every method, and nothing can be paid yet.
      for (final name in [
        'Наличные',
        'Uzcard',
        'Humo',
        'Click',
        'Payme',
        'Перевод'
      ]) {
        expect(field(name), findsOneWidget, reason: name);
      }
      expect(tester.widget<FilledButton>(payButton()).onPressed, isNull);

      await type(tester, 'Наличные', '60000');
      expect(find.textContaining('Qoldi: 40 000'), findsOneWidget);
      expect(tester.widget<FilledButton>(payButton()).onPressed, isNull);

      // "Put the rest here" on the card field.
      final fillRest = find.descendant(
          of: field('Uzcard'), matching: find.byType(IconButton));
      await tester.ensureVisible(fillRest);
      await tester.tap(fillRest);
      await tester.pump();
      expect(
          tester.widget<TextField>(field('Uzcard')).controller!.text, '40000');
      expect(find.text('Summa mos'), findsOneWidget);
      expect(tester.widget<FilledButton>(payButton()).onPressed, isNotNull);
      // Screenshots for eyeballing: flutter test --update-goldens
      if (autoUpdateGoldenFiles) {
        await tester.pump(const Duration(milliseconds: 600)); // labels settle
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('goldens/dialogs/payment_mixed_${size.key}.png'));
      }

      await tester.ensureVisible(payButton());
      await tester.tap(payButton());
      await settle(tester);

      expect(setup.calls, hasLength(1));
      expect(setup.calls.single['p_order_id'], 'o1');
      expect(setup.calls.single['p_payments'], [
        {'payment_method_id': cashId, 'amount': 60000},
        {'payment_method_id': cardId, 'amount': 40000},
      ]);
      // The receipt that opens afterwards lists both methods.
      expect(find.textContaining('Uzcard 40'), findsOneWidget);
      expect(find.textContaining('Наличные 60'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      errors.stop();
      expect(errors.errors, isEmpty, reason: errors.errors.toSet().join('\n'));
    });
  }

  testWidgets('mixed payment with three methods and "too much" is refused',
      (tester) async {
    final setup = Setup();
    await open(tester, setup, sizes['desktop1280']!);
    await tester.tap(find.text('Aralash to\'lov'));
    await tester.pump();

    await type(tester, 'Наличные', '50000');
    await type(tester, 'Uzcard', '30000');
    expect(find.textContaining('Qoldi: 20 000'), findsOneWidget);
    await type(tester, 'Перевод', '30000'); // 110 000: 10 000 too much
    expect(find.textContaining('Ortiqcha: 10 000'), findsOneWidget);
    expect(tester.widget<FilledButton>(payButton()).onPressed, isNull);

    await type(tester, 'Перевод', '20000'); // exactly 100 000
    expect(find.text('Summa mos'), findsOneWidget);
    await tester.ensureVisible(payButton());
    await tester.tap(payButton());
    await settle(tester);
    expect(setup.calls.single['p_payments'], [
      {'payment_method_id': cashId, 'amount': 50000},
      {'payment_method_id': cardId, 'amount': 30000},
      {'payment_method_id': transferId, 'amount': 20000},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a fully typed field of 0 does not become a line',
      (tester) async {
    final setup = Setup();
    await open(tester, setup, sizes['desktop1280']!);
    await tester.tap(find.text('Aralash to\'lov'));
    await tester.pump();
    await type(tester, 'Наличные', '100000');
    await type(tester, 'Uzcard', '0');
    await tester.ensureVisible(payButton());
    await tester.tap(payButton());
    await settle(tester);
    expect(setup.calls.single['p_payments'], [
      {'payment_method_id': cashId, 'amount': 100000},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('if the server did not close the check, it says so and stays',
      (tester) async {
    final setup = Setup(completes: false);
    await open(tester, setup, sizes['desktop1280']!);
    await tester.tap(find.text('Aralash to\'lov'));
    await tester.pump();
    await type(tester, 'Наличные', '100000');
    await tester.ensureVisible(payButton());
    await tester.tap(payButton());
    await settle(tester);
    expect(find.textContaining('Chek yopilmadi'), findsWidgets);
    // The sheet is still there, nothing was shown as paid.
    expect(find.text('Aralash to\'lov'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('single method works as before (one line, cash by default)',
      (tester) async {
    final setup = Setup();
    await open(tester, setup, sizes['desktop1280']!);
    await tester.tap(payButton());
    await settle(tester);
    expect(setup.calls.single['p_payments'], [
      {'payment_method_id': cashId, 'amount': 100000},
    ]);
    await tester.pumpWidget(const SizedBox());
  });
}
