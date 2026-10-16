import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/widgets/promo.dart';

void main() {
  final soon = DateTime.now().add(const Duration(days: 3)).toUtc();
  final past = DateTime.now().subtract(const Duration(days: 1)).toUtc();

  test('the active coupon is the unused, unexpired one', () {
    final promo = {
      'coupons': [
        {
          'id': 'a',
          'status': 'USED',
          'used_order_id': 'o1',
          'expires_at': '$soon'
        },
        {'id': 'b', 'status': 'ACTIVE', 'expires_at': '$past'},
        {'id': 'c', 'status': 'ACTIVE', 'expires_at': '$soon'},
      ]
    };
    expect(activeCoupon(promo)?['id'], 'c');
    expect(usedOn(promo, 'o1')?['id'], 'a');
    expect(usedOn(promo, 'o2'), isNull);
    expect(activeCoupon(null), isNull);
  });

  test('coupon line: free time, hours and the last day', () {
    final line = couponLine({
      'free_minutes': 60,
      'hour_from': 11,
      'hour_to': 17,
      // midnight after the last day -> the 23rd is the last day
      'expires_at': DateTime(2026, 10, 24).toUtc().toIso8601String(),
    });
    expect(line, contains('1 soat bepul'));
    expect(line, contains('11:00–17:00'));
    expect(line, contains('23.10'));
  });

  test('server codes become readable messages', () {
    expect(promoErrorText(Exception('P0001: COUPON_OUTSIDE_HOURS')),
        contains('11:00'));
    expect(promoErrorText(Exception('something else')), isNull);
  });
}
