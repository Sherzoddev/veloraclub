import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n.dart';
import '../theme.dart';

/// "6 tashrif = 1 soat bepul": the bits of the promo every screen shows the
/// same way -- the coupon line, the visit dots, the server's error codes.

const promoGold = Color(0xFFE5B95C);

/// "1 soat bepul · 11:00–17:00 · 23.10 gacha"
String couponLine(Map<String, dynamic> coupon) {
  final minutes = (coupon['free_minutes'] as num?)?.toInt() ?? 60;
  final from = '${coupon['hour_from'] ?? 11}'.padLeft(2, '0');
  final to = '${coupon['hour_to'] ?? 17}'.padLeft(2, '0');
  final until = DateTime.tryParse('${coupon['expires_at']}')
      ?.toLocal()
      .subtract(const Duration(minutes: 1));
  final hours = minutes % 60 == 0
      ? '${minutes ~/ 60} ${tr('soat bepul')}'
      : '$minutes ${tr('daqiqa bepul')}';
  final date = until == null
      ? ''
      : ' · ${DateFormat('dd.MM').format(until)} ${tr('gacha')}';
  return '$hours · $from:00–$to:00$date';
}

/// The active coupon of a customer from a promo state, or null.
Map<String, dynamic>? activeCoupon(Map<String, dynamic>? promo) {
  final list = (promo?['coupons'] as List?) ?? const [];
  for (final c in list) {
    if (c is! Map) continue;
    final until = DateTime.tryParse('${c['expires_at']}');
    if (c['status'] == 'ACTIVE' &&
        (until == null || until.isAfter(DateTime.now()))) {
      return Map<String, dynamic>.from(c);
    }
  }
  return null;
}

/// The coupon put on this order, or null.
Map<String, dynamic>? usedOn(Map<String, dynamic>? promo, String orderId) {
  final list = (promo?['coupons'] as List?) ?? const [];
  for (final c in list) {
    if (c is Map &&
        c['status'] == 'USED' &&
        '${c['used_order_id']}' == orderId) {
      return Map<String, dynamic>.from(c);
    }
  }
  return null;
}

/// Human text for the promo errors the server raises, or null.
String? promoErrorText(Object error) {
  final raw = '$error';
  if (raw.contains('COUPON_OUTSIDE_HOURS')) {
    return tr('Kupon faqat 11:00–17:00 da boshlangan o\'yinga ishlaydi');
  }
  if (raw.contains('COUPON_EXPIRED')) return tr('Kupon muddati tugagan');
  if (raw.contains('COUPON_NOT_ACTIVE')) {
    return tr('Kupon allaqachon ishlatilgan');
  }
  if (raw.contains('COUPON_NO_TIME')) return tr('Bu chekda o\'yin vaqti yo\'q');
  if (raw.contains('COUPON_OTHER_CUSTOMER')) {
    return tr('Kupon boshqa mijozniki');
  }
  return null;
}

/// Six dots, the counted visits filled: ●●●●○○ 4/6
class PromoDots extends StatelessWidget {
  const PromoDots(
      {super.key, required this.visits, this.needed = 6, this.size = 12});

  final int visits;
  final int needed;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < needed; i++)
            Container(
              width: size,
              height: size,
              margin: EdgeInsets.only(right: size * 0.35),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < visits ? VColors.green : Colors.transparent,
                border: Border.all(
                    color: i < visits ? VColors.green : VColors.subtle,
                    width: 1.5),
              ),
            ),
          const SizedBox(width: 4),
          Text('$visits/$needed',
              style: TextStyle(
                  color: VColors.muted,
                  fontWeight: FontWeight.w800,
                  fontSize: size + 1)),
        ],
      );
}

/// The gold "you have a coupon" strip.
class CouponStrip extends StatelessWidget {
  const CouponStrip({super.key, required this.coupon, this.trailing});

  final Map<String, dynamic> coupon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: promoGold.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: promoGold.withValues(alpha: 0.6)),
        ),
        child: Row(children: [
          const Text('🎟', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${tr('Kupon')} ${coupon['code'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w900)),
                Text(couponLine(coupon),
                    style: TextStyle(color: VColors.muted, fontSize: 12.5)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}
