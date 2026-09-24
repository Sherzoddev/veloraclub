import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../services/native_file_picker.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/image_cropper_dialog.dart';

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.controller});
  final ClubController controller;
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  String q = '';
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(30),
      child: Column(children: [
        PageHeader(
            title: 'Tovarlar',
            subtitle: 'Mahsulot katalogi va ombor qoldig\'i',
            actions: [
              OutlinedButton.icon(
                  onPressed: () => _history(context),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Ombor tarixi')),
              FilledButton.icon(
                  onPressed: () => _edit(context, null),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Tovar qo\'shish'))
            ]),
        const SizedBox(height: 18),
        Align(
            alignment: Alignment.centerLeft,
            child: SearchBox(
                width: 400,
                hint: 'Nomi bo\'yicha qidirish...',
                onChanged: (v) => setState(() => q = v.toLowerCase()))),
        const SizedBox(height: 14),
        Expanded(
            child: AsyncPane<List<dynamic>>(
                future: Future.wait([
                  widget.controller.repository
                      .products(widget.controller.context!.clubId),
                  widget.controller.repository
                      .productCategories(widget.controller.context!.clubId),
                ]),
                builder: (context, values) {
                  final rows = (values[0] as List).cast<Map<String, dynamic>>();
                  final cats =
                      (values[1] as List).cast<Map<String, dynamic>>();
                  final f = rows
                      .where((r) => '${r['name']}'.toLowerCase().contains(q))
                      .toList();
                  // Grouped by category — the club's other (web-based) POS
                  // lists products this way, one section per category, rather
                  // than one flat scroll.
                  final groups = <String?, List<Map<String, dynamic>>>{};
                  for (final p in f) {
                    groups
                        .putIfAbsent('${p['category_id'] ?? ''}', () => [])
                        .add(p);
                  }
                  final orderedCatIds = [
                    for (final c in cats)
                      if (groups.containsKey('${c['id']}')) '${c['id']}',
                    if (groups.containsKey('')) '',
                  ];
                  return ListView(
                    children: [
                      for (final catId in orderedCatIds) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 8),
                          child: Text(
                              catId.isEmpty
                                  ? 'Toifasiz'
                                  : '${cats.firstWhere((c) => '${c['id']}' == catId)['name']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 16)),
                        ),
                        for (final p in groups[catId]!)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _ProductListItem(
                              product: p,
                              onArrival: () => _stock(context, p, true),
                              onWriteOff: () => _stock(context, p, false),
                              onEdit: () => _edit(context, p),
                              onDelete: () => _delete(context, p),
                            ),
                          ),
                      ],
                    ],
                  );
                }))
      ]));
  Future<void> _history(BuildContext context) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await widget.controller.repository
          .stockMovements(widget.controller.context!.clubId);
    } catch (e) {
      if (context.mounted) showError(context, e);
      return;
    }
    if (!context.mounted) return;
    final df = DateFormat('dd.MM HH:mm');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ombor tarixi'),
        content: SizedBox(
          width: 560,
          height: 560,
          child: rows.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Harakatlar yo\'q',
                  subtitle: 'Ombor bo\'yicha hali hech narsa qayd etilmagan',
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 22, color: VColors.subtle.withValues(alpha: 0.2)),
                  itemBuilder: (context, i) {
                    final m = rows[i];
                    final product = m['products'];
                    final name =
                        product is Map ? '${product['name']}' : 'Tovar';
                    final delta =
                        (num.tryParse('${m['quantity_delta']}') ?? 0);
                    final positive = delta > 0;
                    final createdAt = DateTime.tryParse('${m['created_at']}')
                        ?.toLocal();
                    final note = m['note'];
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15)),
                              const SizedBox(height: 3),
                              Text(
                                  '${m['kind'] ?? ''}${note != null && '$note'.isNotEmpty ? ' · $note' : ''}',
                                  style: TextStyle(
                                      color: VColors.subtle, fontSize: 13)),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                                '${positive ? '+' : ''}${delta.toStringAsFixed(delta % 1 == 0 ? 0 : 2)}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: positive
                                        ? VColors.greenDark
                                        : VColors.red)),
                            const SizedBox(height: 3),
                            Text(
                                createdAt == null ? '' : df.format(createdAt),
                                style: TextStyle(
                                    color: VColors.subtle, fontSize: 12)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Yopish')),
        ],
      ),
    );
  }

  /// [positive] just steers the label/sign of the dialog and default hint —
  /// the amount typed is still what actually determines direction, matching
  /// the single-field arrival/write-off flow this app already had.
  Future<void> _stock(
      BuildContext context, Map<String, dynamic> p, bool positive) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(
                    '${p['name']} · ${positive ? 'Kirim' : 'Chiqim'}'),
                content: TextField(
                    controller: c,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: positive
                            ? 'Miqdor (kirim)'
                            : 'Miqdor (chiqim)')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Bekor qilish')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Saqlash'))
                ]));
    if (ok == true) {
      final raw = num.tryParse(c.text) ?? 0;
      final d = positive ? raw.abs() : -raw.abs();
      if (d == 0) return;
      try {
        await widget.controller.repository.client
            .from('stock_movements')
            .insert({
          'club_id': widget.controller.context!.clubId,
          'product_id': p['id'],
          'kind': d >= 0 ? 'PURCHASE' : 'WRITE_OFF',
          'quantity_delta': d,
          'quantity_after': (p['stock_quantity'] as num? ?? 0) + d,
          'created_by': widget.controller.repository.user!.id
        });
        await widget.controller.repository.client.from('products').update({
          'stock_quantity': (p['stock_quantity'] as num? ?? 0) + d
        }).eq('id', p['id']);
        widget.controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('O\'chirish'),
        content: Text('«${p['name']}» sotuvdan yo\'qoladi.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Yo\'q')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VColors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('O\'chirish')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.repository.client.from('products').update({
        'archived_at': DateTime.now().toUtc().toIso8601String(),
        'active': false,
      }).eq('id', p['id']);
      widget.controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? p) async {
    final cats = await widget.controller.repository
        .productCategories(widget.controller.context!.clubId);
    if (!context.mounted) return;
    final name = TextEditingController(text: '${p?['name'] ?? ''}'),
        price = TextEditingController(text: '${p?['sale_price'] ?? ''}'),
        purchase = TextEditingController(text: '${p?['purchase_price'] ?? ''}'),
        barcode = TextEditingController(text: '${p?['barcode'] ?? ''}'),
        imageUrl = TextEditingController(text: '${p?['image_url'] ?? ''}');
    String? category =
        p?['category_id']?.toString() ?? cats.firstOrNull?['id']?.toString();
    String unit = '${p?['unit'] ?? 'dona'}';
    bool active = p?['active'] as bool? ?? true;
    bool uploadingImage = false;
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
                    title: Text(
                        p == null ? 'Tovar qo\'shish' : 'Tovarni tahrirlash'),
                    content: SizedBox(
                        width: 500,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              controller: name,
                              autofocus: true,
                              decoration:
                                  const InputDecoration(labelText: 'Nomi')),
                          const SizedBox(height: 14),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Tovar rasmi',
                                style: TextStyle(
                                    color: VColors.subtle, fontSize: 12)),
                          ),
                          const SizedBox(height: 6),
                          if (uploadingImage)
                            Container(
                              width: 120,
                              height: 120,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: VColors.field,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              margin: const EdgeInsets.only(bottom: 8),
                              child: const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          else if (imageUrl.text.trim().isNotEmpty)
                            // Square, matching both the crop tool's canvas and
                            // the sale grid's ProductGridCard -- a landscape
                            // preview box here used to double-letterbox the
                            // now-always-square cropped photo, making it look
                            // squeezed instead of showing it 1:1 like it will
                            // actually appear on the grid.
                            Container(
                              width: 120,
                              height: 120,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: VColors.field,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              clipBehavior: Clip.antiAlias,
                              margin: const EdgeInsets.only(bottom: 8),
                              child: Image.network(imageUrl.text.trim(),
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Icon(
                                      Icons.image_not_supported_outlined,
                                      color: VColors.subtle)),
                            ),
                          Row(children: [
                                      OutlinedButton.icon(
                                        onPressed: uploadingImage
                                            ? null
                                            : () async {
                                                try {
                                                  final pickedPath =
                                                      pickFileNative(
                                                    title: 'Rasm tanlash',
                                                    extensions: [
                                                      'png',
                                                      'jpg',
                                                      'jpeg'
                                                    ],
                                                  );
                                                  if (pickedPath == null) {
                                                    return;
                                                  }
                                                  final rawBytes =
                                                      await File(pickedPath)
                                                          .readAsBytes();
                                                  if (!context.mounted) {
                                                    return;
                                                  }
                                                  // A fixed 3:2 crop before upload, not the raw
                                                  // file — different source photos otherwise
                                                  // made the sale grid look inconsistent (some
                                                  // filled the card, others floated tiny with
                                                  // empty space around them).
                                                  final cropped =
                                                      await showDialog<Uint8List>(
                                                    context: context,
                                                    builder: (_) =>
                                                        ImageCropperDialog(
                                                            bytes: rawBytes),
                                                  );
                                                  if (cropped == null) return;
                                                  setState(() =>
                                                      uploadingImage = true);
                                                  final bytes = cropped;
                                                  final clubId = widget
                                                      .controller
                                                      .context!
                                                      .clubId;
                                                  const ext = 'png';
                                                  // A fresh, unique filename every upload (not
                                                  // just for new products) so the returned URL
                                                  // always differs from the previous one --
                                                  // reusing the same path let Image.network (and
                                                  // any other cached viewer) keep showing the old
                                                  // bytes after a replacement upload.
                                                  final fileName =
                                                      '${p?['id'] ?? 'new'}-${DateTime.now().millisecondsSinceEpoch}.$ext';
                                                  final path =
                                                      '$clubId/products/$fileName';
                                                  final storage = widget
                                                      .controller
                                                      .repository
                                                      .client
                                                      .storage
                                                      .from('club-assets');
                                                  await storage.uploadBinary(
                                                      path, bytes,
                                                      fileOptions:
                                                          FileOptions(
                                                              contentType:
                                                                  'image/png',
                                                              upsert: true));
                                                  final url = storage
                                                      .getPublicUrl(path);
                                                  setState(() {
                                                    imageUrl.text = url;
                                                  });
                                                } catch (e) {
                                                  if (context.mounted) {
                                                    showError(context, e);
                                                  }
                                                } finally {
                                                  setState(() =>
                                                      uploadingImage = false);
                                                }
                                              },
                                        icon: const Icon(Icons.upload_rounded,
                                            size: 16),
                                        label: const Text('Rasm yuklash'),
                                        style: OutlinedButton.styleFrom(
                                          minimumSize: const Size(0, 34),
                                          textStyle:
                                              const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                    ]),
                          const SizedBox(height: 6),
                          Text(
                              'Fayl tanlangandan keyin rasmni kesib, kerakli qismini yaqinlashtirish mumkin.',
                              style:
                                  TextStyle(color: VColors.subtle, fontSize: 12)),
                          if (imageUrl.text.trim().isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: uploadingImage
                                    ? null
                                    : () => setState(() => imageUrl.clear()),
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 30),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  foregroundColor: VColors.subtle,
                                ),
                                child: const Text('Rasmni o\'chirish'),
                              ),
                            ),
                          const SizedBox(height: 14),
                          Row(children: [
                            Expanded(
                              child: TextField(
                                  controller: price,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Sotuv narxi')),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                  controller: purchase,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Tannarx')),
                            ),
                          ]),
                          const SizedBox(height: 14),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Toifa',
                                style: TextStyle(
                                    color: VColors.subtle, fontSize: 12)),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 38,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: cats.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (_, i) {
                                final c = cats[i];
                                return ChoiceChip(
                                    label: Text('${c['name']}'),
                                    selected: category == '${c['id']}',
                                    onSelected: (_) => setState(
                                        () => category = '${c['id']}'));
                              },
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                              controller: barcode,
                              decoration: const InputDecoration(
                                  labelText: 'Shtrix-kod')),
                          const SizedBox(height: 14),
                          Row(children: [
                            const Text('Sotuvda ko\'rsatish'),
                            const Spacer(),
                            Switch(
                              value: active,
                              onChanged: (v) => setState(() => active = v),
                            ),
                          ]),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Bekor qilish')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Saqlash'))
                    ])));
    if (ok == true) {
      final data = {
        'club_id': widget.controller.context!.clubId,
        'category_id': category,
        'name': name.text.trim(),
        'sale_price': int.tryParse(price.text) ?? 0,
        'purchase_price': int.tryParse(purchase.text) ?? 0,
        'unit': unit,
        'active': active,
        'barcode': barcode.text.trim().isEmpty ? null : barcode.text.trim(),
        'image_url': imageUrl.text.trim().isEmpty ? null : imageUrl.text.trim(),
      };
      try {
        if (p == null) {
          await widget.controller.repository.client
              .from('products')
              .insert(data);
        } else {
          await widget.controller.repository.client
              .from('products')
              .update(data)
              .eq('id', p['id']);
        }
        widget.controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }
}

/// A product row for the catalog list — mirrors the club's other (web-based)
/// POS `.list-item`: thumbnail + name/margin/stock on top, a row of action
/// buttons underneath instead of squeezing everything into one line.
class _ProductListItem extends StatelessWidget {
  const _ProductListItem({
    required this.product,
    required this.onArrival,
    required this.onWriteOff,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> product;
  final VoidCallback onArrival;
  final VoidCallback onWriteOff;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final cat = p['product_categories'];
    final catColor = cat is Map && cat['color'] != null
        ? Color(int.parse('${cat['color']}'.replaceFirst('#', 'FF'), radix: 16))
        : null;
    final active = p['active'] != false;
    final salePrice = (p['sale_price'] as num?)?.toInt() ?? 0;
    final purchasePrice = (p['purchase_price'] as num?)?.toInt() ?? 0;
    final margin = salePrice - purchasePrice;
    final stock = (p['stock_quantity'] as num?) ?? 0;
    final unit = '${p['unit'] ?? 'dona'}';
    final imageUrl = p['image_url'] as String?;
    return Opacity(
      opacity: active ? 1 : .6,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: VColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border(
            top: BorderSide(color: VColors.line),
            bottom: BorderSide(color: VColors.line),
            left: BorderSide(
                color: catColor ?? VColors.line, width: catColor != null ? 4 : 1),
            right: BorderSide(
                color: catColor ?? VColors.line, width: catColor != null ? 4 : 1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (imageUrl != null && imageUrl.isNotEmpty)
                  Container(
                    width: 32,
                    height: 32,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.network(imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox()),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(active ? '${p['name']}' : '${p['name']} (yashirilgan)',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text(
                          'Tannarx: ${money(purchasePrice)} · Marja: ${money(margin)}',
                          style:
                              TextStyle(color: VColors.muted, fontSize: 13)),
                      const SizedBox(height: 3),
                      Text('Qoldiq: ${stock == stock.roundToDouble() ? stock.toInt() : stock} $unit',
                          style: TextStyle(
                              color: stock <= 0 ? VColors.red : VColors.muted,
                              fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(money(salePrice),
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    if (unit == 'kg')
                      Text('/kg',
                          style:
                              TextStyle(color: VColors.muted, fontSize: 12)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(
                  onPressed: onArrival,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32)),
                  child: const Text('Kirim')),
              OutlinedButton(
                  onPressed: onWriteOff,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32)),
                  child: const Text('Chiqim')),
              OutlinedButton(
                  onPressed: onEdit,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32)),
                  child: const Text('O\'zgartirish')),
              FilledButton.icon(
                  onPressed: onDelete,
                  style: FilledButton.styleFrom(
                      backgroundColor: VColors.red,
                      minimumSize: const Size(0, 32)),
                  icon: const Icon(Icons.close_rounded, size: 14),
                  label: const Text('O\'chirish')),
            ]),
          ],
        ),
      ),
    );
  }
}
