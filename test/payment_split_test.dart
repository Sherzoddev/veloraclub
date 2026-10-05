import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/payment_split.dart';

void main() {
  final methods = [
    {'id': 'cash', 'name': 'Наличные'},
    {'id': 'card', 'name': 'Uzcard'},
    {'id': 'transfer', 'name': 'Перевод'},
  ];

  test('numbers are read the way people type them', () {
    expect(PaymentSplit.parse('50000'), 50000);
    expect(PaymentSplit.parse('50 000'), 50000);
    expect(PaymentSplit.parse('50 000 so\'m'), 50000);
    expect(PaymentSplit.parse(''), 0);
    expect(PaymentSplit.parse('abc'), 0);
    expect(
        PaymentSplit.parse('-5'), 5); // a minus is not a digit: never negative
  });

  test('remaining is short, exact or too much', () {
    expect(PaymentSplit.remaining(100000, ['50000', '30000']), 20000);
    expect(PaymentSplit.remaining(100000, ['50000', '50000']), 0);
    expect(PaymentSplit.remaining(100000, ['70000', '50000']), -20000);
    expect(PaymentSplit.remaining(100000, const []), 100000);
  });

  test('only methods with an amount become lines, in the club order', () {
    final lines = PaymentSplit.lines(
        methods, {'transfer': '20000', 'cash': '50000', 'card': ''});
    expect(lines.map((l) => (l.methodId, l.amount)).toList(),
        [('cash', 50000), ('transfer', 20000)]);
  });

  test('a zero or empty field is not a line', () {
    expect(PaymentSplit.lines(methods, {'cash': '0', 'card': ' '}), isEmpty);
  });

  test('complete only when the amounts match the total exactly', () {
    expect(PaymentSplit.isComplete(100000, {'cash': '60000', 'card': '40000'}),
        isTrue);
    expect(PaymentSplit.isComplete(100000, {'cash': '60000', 'card': '30000'}),
        isFalse);
    expect(PaymentSplit.isComplete(100000, {'cash': '60000', 'card': '50000'}),
        isFalse);
    expect(PaymentSplit.isComplete(0, {}), isFalse); // nothing to pay
  });

  test('"fill the rest" counts everything typed in the other fields', () {
    final texts = {'cash': '50000', 'card': '', 'transfer': '10000'};
    expect(PaymentSplit.fillFor('card', 100000, texts), 40000);
    // The field's own text is not counted: re-pressing the button is stable.
    texts['card'] = '40000';
    expect(PaymentSplit.fillFor('card', 100000, texts), 40000);
    // Too much elsewhere: never a negative amount.
    expect(PaymentSplit.fillFor('card', 30000, texts), 0);
  });

  test('receipt label lists every method with its amount', () {
    final lines =
        PaymentSplit.lines(methods, {'cash': '50000', 'card': '30000'});
    expect(PaymentSplit.label(lines, (a) => '$a so\'m'),
        'Наличные 50000 so\'m, Uzcard 30000 so\'m');
  });
}
