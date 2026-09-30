import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/widgets/common.dart';

void main() {
  // The sale grids size a card by a fixed cell ratio (.72). With a square
  // photo on top, the stock line ("15 шт") fell below the cell and was cut
  // off at typical cashier-screen widths.
  for (final width in [150.0, 170.0, 220.0]) {
    testWidgets('product card fits a ${width.toInt()}px grid cell',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: width / .72,
              child: ProductGridCard(
                product: const {
                  'name': 'Кока кола бутылка',
                  'sale_price': 5000,
                  'stock_quantity': 15,
                  'unit': 'шт',
                },
                onTap: () {},
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('15 шт'), findsOneWidget);
      final card = tester.getRect(find.byType(Card));
      final stock = tester.getRect(find.text('15 шт'));
      expect(stock.bottom, lessThanOrEqualTo(card.bottom));
    });
  }

  // Tea by the cup or a hookah has no stock to count: with track_stock off
  // the card reads "on sale" instead of "out of stock", even at 0.
  testWidgets('untracked product reads as on sale at zero stock',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 170,
            height: 170 / .72,
            child: ProductGridCard(
              product: const {
                'name': 'Кальян',
                'sale_price': 60000,
                'stock_quantity': 0,
                'track_stock': false,
                'unit': 'шт',
              },
              onTap: () {},
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Sotuvda'), findsOneWidget);
    expect(find.text('Mavjud emas'), findsNothing);
  });
}
