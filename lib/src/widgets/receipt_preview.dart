import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/receipt_builder.dart';
import '../utils.dart';

/// Renders a receipt exactly like Sozlamalar → Chek's own preview (same
/// fonts, dashed dividers, logo, meta lines) — used everywhere an on-screen
/// receipt is shown (Cheklar, To'lov) so they never drift out of sync with
/// what the cashier configured.
class ReceiptPreview extends StatelessWidget {
  const ReceiptPreview({
    super.key,
    required this.club,
    required this.cashierName,
    this.resourceName,
    this.pricePerHour,
    this.familyLabel,
    this.sessionStartedAt,
    this.sessionEndedAt,
    this.receiptNumber,
    required this.date,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethodName,
  });

  final Map<String, dynamic> club;
  final String cashierName;
  final String? resourceName;
  final num? pricePerHour;
  final String? familyLabel;
  final DateTime? sessionStartedAt;
  final DateTime? sessionEndedAt;
  final int? receiptNumber;
  final DateTime date;
  final List<ReceiptLine> lines;
  final int subtotal;
  final int discount;
  final int total;
  final String paymentMethodName;

  static const _ink = Color(0xFF101010);
  static const _muted = Color(0xFF6B6B6B);

  @override
  Widget build(BuildContext context) {
    final paperMm = (club['receipt_paper_mm'] as num?)?.toInt() ?? 58;
    final fontTitle = (club['receipt_font_title'] as num?)?.toDouble() ?? 30;
    final fontTotal = (club['receipt_font_total'] as num?)?.toDouble() ?? 20;
    final fontMeta = (club['receipt_font_meta'] as num?)?.toDouble() ?? 15;
    final fontItems = (club['receipt_font_items'] as num?)?.toDouble() ?? 15;
    final fontFooter = (club['receipt_font_footer'] as num?)?.toDouble() ?? 15;
    final fontQrCaption =
        (club['receipt_font_qr_caption'] as num?)?.toDouble() ?? 15;
    final printCost = club['receipt_print_cost'] == true;
    final logoUrl = club['logo_url'] as String?;
    final subtitle = club['receipt_subtitle'] as String?;
    final phone = club['receipt_phone'] as String?;
    final footer = club['receipt_footer'] as String?;
    final qrEnabled = club['receipt_qr_enabled'] != false;
    final qrUrl = club['receipt_qr_url'] as String?;
    final qrCaption = club['receipt_qr_caption'] as String?;
    final title = (club['receipt_header'] as String?)?.trim().isNotEmpty == true
        ? club['receipt_header'] as String
        : '${club['name'] ?? ''}';
    final timeLines = lines.where((l) => l.kind == 'time').toList();
    final productLines = lines.where((l) => l.kind != 'time').toList();
    final timeTotal = timeLines.fold<int>(0, (s, l) => s + l.amount);

    return Container(
      width: paperMm >= 80 ? 400 : 320,
      color: Colors.white,
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          if (logoUrl != null && logoUrl.isNotEmpty) ...[
            Image.network(logoUrl, height: 60),
            const SizedBox(height: 10),
          ],
          Text(title.toUpperCase(),
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  fontSize: fontTitle)),
          if (subtitle != null && subtitle.trim().isNotEmpty)
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: fontMeta)),
          if (phone != null && phone.trim().isNotEmpty)
            Text(phone,
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: fontMeta)),
          const SizedBox(height: 10),
          _dashedDivider(),
          const SizedBox(height: 10),
          Text('Sana: ${_isoDate(date)}',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, fontSize: fontMeta)),
          Text(receiptNumber != null ? 'Chek №$receiptNumber' : 'Chek',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  fontSize: fontMeta)),
          const SizedBox(height: 8),
          _line('Kassir:', cashierName, fontMeta),
          if (sessionStartedAt != null)
            _line(
                'Boshlanishi:', _clockWithSeconds(sessionStartedAt!), fontMeta),
          if (sessionEndedAt != null)
            _line('Tugash:', _clockWithSeconds(sessionEndedAt!), fontMeta),
          if (sessionStartedAt != null && sessionEndedAt != null)
            _line(
                'Davomiylik:',
                _durationPrecise(sessionEndedAt!.difference(sessionStartedAt!)),
                fontMeta),
          if (resourceName != null) ...[
            const SizedBox(height: 10),
            _dashedDivider(),
            const SizedBox(height: 10),
            _line('Stol:', resourceName!, fontMeta),
            if (pricePerHour != null)
              _line('Soatlik narx:', '${money(pricePerHour)}/soat', fontMeta),
          ],
          if (timeLines.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dashedDivider(),
            const SizedBox(height: 10),
            Text((familyLabel ?? 'Vaqt').toUpperCase(),
                style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                    fontSize: fontItems)),
            _line('Narxi:', money(timeTotal), fontMeta),
            const SizedBox(height: 6),
            _dashedDivider(),
            const SizedBox(height: 6),
            Text('ORALIQ VAQTLAR',
                style: TextStyle(color: _muted, fontSize: fontMeta)),
            for (final l in timeLines) ...[
              _item(
                  l.startedAt != null && l.endedAt != null
                      ? '${_clock(l.startedAt!)} - ${_clock(l.endedAt!)} '
                          '(${l.endedAt!.difference(l.startedAt!).inMinutes} min)'
                      : (l.quantity != null
                          ? '${l.quantity} × ${l.label}'
                          : l.label),
                  money(l.amount),
                  fontItems),
              if (l.note != null && l.note!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('  ${l.note}',
                      style: TextStyle(color: _muted, fontSize: 12)),
                ),
            ],
          ],
          if (productLines.isNotEmpty) ...[
            const SizedBox(height: 10),
            _dashedDivider(),
            const SizedBox(height: 10),
            Text('TOVARLAR',
                style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                    fontSize: fontItems)),
            for (final l in productLines) ...[
              _item(l.quantity != null ? '${l.quantity} × ${l.label}' : l.label,
                  money(l.amount), fontItems),
              if (l.note != null && l.note!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('  ${l.note}',
                      style: TextStyle(color: _muted, fontSize: 12)),
                ),
              if (printCost && l.cost != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('  tannarx: ${money(l.cost!)}',
                      style: TextStyle(color: _muted, fontSize: 12)),
                ),
            ],
          ],
          const SizedBox(height: 10),
          _dashedDivider(),
          const SizedBox(height: 10),
          if (discount > 0) ...[
            _item('Oraliq summa', money(subtotal), fontItems),
            _item('Chegirma', '-${money(discount)}', fontItems),
            const SizedBox(height: 4),
          ],
          _item('JAMI', money(total), fontTotal, bold: true),
          _line('To\'lov:', paymentMethodName, fontMeta),
          const SizedBox(height: 10),
          _dashedDivider(),
          const SizedBox(height: 10),
          if (footer != null && footer.trim().isNotEmpty)
            Text(footer,
                textAlign: TextAlign.center,
                style: TextStyle(color: _ink, fontSize: fontFooter)),
          if (qrEnabled && qrUrl != null && qrUrl.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _dashedDivider(),
            const SizedBox(height: 12),
            if (qrCaption != null && qrCaption.trim().isNotEmpty)
              Text(qrCaption,
                  style: TextStyle(color: _ink, fontSize: fontQrCaption)),
            const SizedBox(height: 10),
            QrImageView(data: qrUrl, size: 130),
          ],
        ],
      ),
    );
  }

  String _clock(DateTime d) {
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  String _clockWithSeconds(DateTime d) {
    final l = d.toLocal();
    return '${_clock(d)}:${l.second.toString().padLeft(2, '0')}';
  }

  String _durationPrecise(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    return '$m daqiqa $s soniya';
  }

  String _isoDate(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }

  Widget _dashedDivider() => SizedBox(
        width: double.infinity,
        child: Text(
          '- ' * 24,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(color: _muted, fontSize: 12, height: 0.6),
        ),
      );

  Widget _line(String label, String value, double size) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Text(label, style: TextStyle(color: _ink, fontSize: size)),
          const SizedBox(width: 6),
          Expanded(
              child:
                  Text(value, style: TextStyle(color: _ink, fontSize: size))),
        ]),
      );

  Widget _item(String label, String amount, double size, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: _ink,
                      fontSize: size,
                      fontWeight: bold ? FontWeight.w900 : FontWeight.normal))),
          Text(amount,
              style: TextStyle(
                  color: _ink,
                  fontSize: size,
                  fontWeight: bold ? FontWeight.w900 : FontWeight.normal)),
        ]),
      );
}
