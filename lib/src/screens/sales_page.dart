import 'package:flutter/material.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/customer_picker.dart';
import 'session_payment_dialog.dart';

class SalesPage extends StatefulWidget {
  const SalesPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  final search = TextEditingController();
  final barcode = TextEditingController();
  final Map<String, _CartLine> cart = {};
  String query = '';
  String category = 'ALL';
  bool paying = false;
  String? selectedCustomer;
  String? customerLabel;
  int discountPercent = 0;
  final customDiscount = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    barcode.dispose();
    customDiscount.dispose();
    super.dispose();
  }

  int get subtotal => cart.values.fold(0, (sum, e) => sum + e.total);
  int get discountAmount => (subtotal * discountPercent / 100).round();
  int get total => subtotal - discountAmount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 22, 16),
      child: AsyncPane<List<Map<String, dynamic>>>(
        future:
            widget.controller.repository.shifts(widget.controller.context!.clubId),
        builder: (context, shifts) {
          final openShift =
              shifts.where((s) => s['status'] == 'OPEN').firstOrNull;
          if (openShift == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EmptyState(
                    icon: Icons.point_of_sale_outlined,
                    title: tr('Smena yopiq'),
                    subtitle: tr('Savdoni boshlash uchun avval smenani oching'),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => widget.controller.go(6),
                    icon: const Icon(Icons.lock_open_rounded),
                    label: Text(tr('Smenaga o\'tish')),
                  ),
                ],
              ),
            );
          }
          return _sotuvBody(context);
        },
      ),
    );
  }

  Widget _sotuvBody(BuildContext context) {
    return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageHeader(title: tr('Sotuv')),
                const SizedBox(height: 14),
                Row(
                  children: [
                    SizedBox(
                      width: 380,
                      height: 46,
                      child: TextField(
                        controller: barcode,
                        autofocus: true,
                        onSubmitted: _barcode,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: tr('Shtrix-kodni skanerlang'),
                          isDense: true,
                          filled: true,
                          fillColor: VColors.bg,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: VColors.line)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: VColors.line)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide:
                                  BorderSide(color: VColors.green, width: 1.5)),
                          prefixIcon: Icon(Icons.qr_code_scanner_rounded,
                              color: VColors.green, size: 19),
                          suffixIcon: const Icon(
                              Icons.keyboard_return_rounded,
                              size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SearchBox(
                      hint: tr('Tovar qidirish...'),
                      controller: search,
                      width: 330,
                      dense: true,
                      onChanged: (v) => setState(() => query = v.toLowerCase()),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: AsyncPane<List<dynamic>>(
                    future: Future.wait([
                      widget.controller.repository
                          .products(widget.controller.context!.clubId),
                      widget.controller.repository
                          .productCategories(widget.controller.context!.clubId),
                      widget.controller.repository
                          .productSalesStats(widget.controller.context!.clubId),
                    ]),
                    builder: (context, values) {
                      final products =
                          values[0] as List<Map<String, dynamic>>;
                      final categories =
                          values[1] as List<Map<String, dynamic>>;
                      final sales = values[2] as Map<String, num>;
                      final filtered = products
                          .where((p) => p['active'] == true)
                          .where((p) => category == 'ALL' ||
                              '${p['category_id']}' == category)
                          .where((p) =>
                              '${p['name']}'.toLowerCase().contains(query))
                          .toList()
                        ..sort((a, b) {
                          final sa = sales['${a['id']}'] ?? 0;
                          final sb = sales['${b['id']}'] ?? 0;
                          if (sa != sb) return sb.compareTo(sa);
                          return '${a['name']}'.compareTo('${b['name']}');
                        });
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (categories.isNotEmpty)
                            SizedBox(
                              height: 76,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  CategoryIconChip(
                                    label: tr('Barchasi'),
                                    isAll: true,
                                    selected: category == 'ALL',
                                    onTap: () =>
                                        setState(() => category = 'ALL'),
                                  ),
                                  for (final (i, c) in categories.indexed)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(left: 8),
                                      child: CategoryIconChip(
                                        label: '${c['name']}',
                                        selected: category == '${c['id']}',
                                        icon: c['icon'] as String?,
                                        fallbackIndex: i,
                                        color: c['color'] != null
                                            ? Color(int.parse(
                                                '${c['color']}'.replaceFirst(
                                                    '#', 'FF'),
                                                radix: 16))
                                            : null,
                                        onTap: () => setState(
                                            () => category = '${c['id']}'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (categories.isNotEmpty)
                            const SizedBox(height: 12),
                          Expanded(
                            child: LayoutBuilder(
                                builder: (context, constraints) {
                              final count = (constraints.maxWidth / 175)
                                  .floor()
                                  .clamp(2, 7);
                              return GridView.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: count,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: .72,
                                ),
                                itemCount: filtered.length,
                                itemBuilder: (context, i) {
                                  final p = filtered[i];
                                  final stock =
                                      (p['stock_quantity'] as num?) ?? 0;
                                  return ProductGridCard(
                                    product: p,
                                    onTap: stock > 0 ? () => _add(p) : null,
                                  );
                                },
                              );
                            }),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          SizedBox(
            width: 370,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(tr('Savat'),
                            style: Theme.of(context).textTheme.titleLarge),
                        if (cart.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                                color: VColors.greenSoft,
                                borderRadius: BorderRadius.circular(20)),
                            child: Text('${cart.length}',
                                style: TextStyle(
                                    color: VColors.greenDark,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12)),
                          ),
                        ],
                        const Spacer(),
                        if (cart.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() {
                              cart.clear();
                              discountPercent = 0;
                              customDiscount.clear();
                            }),
                            child: Text(tr('Tozalash')),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _chooseCustomer,
                        icon: const Icon(Icons.person_outline_rounded,
                            size: 18),
                        label: Text(customerLabel ?? tr('Mijozsiz')),
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: cart.isEmpty
                          ? EmptyState(
                              icon: Icons.receipt_long_outlined,
                              title: tr('Chek bo\'sh'),
                              subtitle: tr('Chekka qo\'shish uchun tovar tanlang'),
                            )
                          : ListView.separated(
                              itemCount: cart.length,
                              separatorBuilder: (_, __) =>
                                  Divider(height: 1, color: VColors.line),
                              itemBuilder: (context, i) {
                                final line = cart.values.elementAt(i);
                                return _Line(
                                  line: line,
                                  changed: (delta) {
                                    setState(() {
                                      line.quantity += delta;
                                      if (line.quantity <= 0) {
                                        cart.remove(line.id);
                                      }
                                    });
                                  },
                                  onRemove: () =>
                                      setState(() => cart.remove(line.id)),
                                );
                              },
                            ),
                    ),
                    if (cart.isNotEmpty) ...[
                      const Divider(),
                      Text(tr('Chegirma'),
                          style: TextStyle(
                              color: VColors.muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          for (final pct in [0, 5, 10, 15])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(pct == 0 ? '0%' : '$pct%'),
                                selected: discountPercent == pct,
                                onSelected: (_) => setState(() {
                                  discountPercent = pct;
                                  customDiscount.clear();
                                }),
                              ),
                            ),
                          Expanded(
                            child: SizedBox(
                              height: 34,
                              child: TextField(
                                controller: customDiscount,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: '%',
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 8),
                                ),
                                onChanged: (v) => setState(() =>
                                    discountPercent =
                                        int.tryParse(v)?.clamp(0, 100) ?? 0),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        Text(tr('Oraliq summa'),
                            style: TextStyle(color: VColors.muted)),
                        const Spacer(),
                        Text(money(subtotal)),
                      ]),
                      if (discountAmount > 0) ...[
                        const SizedBox(height: 4),
                        Row(children: [
                          Text(tr('Chegirma'), style: TextStyle(color: VColors.muted)),
                          const Spacer(),
                          Text('-${money(discountAmount)}',
                              style: TextStyle(color: VColors.red)),
                        ]),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(tr('Jami'),
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w900)),
                          const Spacer(),
                          Text(money(total),
                              style: TextStyle(
                                  color: VColors.greenDark,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w900)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: paying ? null : _pay,
                          // Explicit colors for the disabled (paying) state
                          // too -- FilledButton's default disabled look is a
                          // flat grey, so without this the button visibly
                          // flashes from green to grey the instant payment
                          // starts instead of just swapping in a spinner.
                          style: FilledButton.styleFrom(
                              foregroundColor: Colors.black87,
                              disabledBackgroundColor: VColors.green,
                              disabledForegroundColor: Colors.black87),
                          icon: paying
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.black87))
                              : const Icon(Icons.payments_outlined),
                          label: Text('${tr('To\'lash')} — ${money(total)}'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
    );
  }

  void _add(Map<String, dynamic> product) {
    final stock = (product['stock_quantity'] as num?) ?? 0;
    final id = '${product['id']}';
    final already = cart[id]?.quantity ?? 0;
    if (stock <= 0 || already >= stock) {
      showError(context, tr('Tovar qoldig\'i yetarli emas'));
      return;
    }
    setState(() {
      cart.update(id, (line) {
        line.quantity += 1;
        return line;
      }, ifAbsent: () => _CartLine(product));
    });
  }

  Future<void> _barcode(String code) async {
    if (code.trim().isEmpty) return;
    try {
      final value = await widget.controller.repository.client.rpc(
        'product_by_barcode',
        params: {
          'p_club_id': widget.controller.context!.clubId,
          'p_barcode': code.trim(),
        },
      );
      final result = rowMap(value);
      if (result['found'] == true && result['product'] is Map) {
        _add(Map<String, dynamic>.from(result['product'] as Map));
        barcode.clear();
      } else if (mounted) {
        showError(context, '${tr('Tovar topilmadi')}: $code');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _chooseCustomer() async {
    final rows = await widget.controller.repository
        .customers(widget.controller.context!.clubId);
    if (!mounted) return;
    final id = await pickCustomer(context, rows);
    if (id == null) return;
    final row = rows.firstWhere((c) => '${c['id']}' == id,
        orElse: () => const {});
    setState(() {
      selectedCustomer = id;
      customerLabel = row['full_name'] as String?;
    });
  }

  Future<void> _pay() async {
    if (paying) return;
    setState(() => paying = true);
    try {
      final repo = widget.controller.repository;
      final created = await repo.createWalkinOrder(
          widget.controller.context!.clubId, selectedCustomer);
      final order = (created['order'] as Map?) ?? created;
      final orderId = '${order['id']}';
      for (final line in cart.values) {
        await repo.addOrderItem(orderId, line.id, line.quantity);
      }
      if (discountAmount > 0) {
        await repo.applyDiscount(orderId,
            amount: discountAmount, reason: '$discountPercent%');
      }
      if (!mounted) return;
      await showSessionPaymentDialog(
        context,
        controller: widget.controller,
        orderId: orderId,
      );
      setState(() {
        cart.clear();
        selectedCustomer = null;
        customerLabel = null;
        discountPercent = 0;
        customDiscount.clear();
      });
      widget.controller.refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => paying = false);
    }
  }
}

class _CartLine {
  _CartLine(this.product);
  final Map<String, dynamic> product;
  int quantity = 1;
  String get id => '${product['id']}';
  int get price => (product['sale_price'] as num?)?.toInt() ?? 0;
  int get total => price * quantity;
}

class _Line extends StatelessWidget {
  const _Line(
      {required this.line, required this.changed, required this.onRemove});
  final _CartLine line;
  final ValueChanged<int> changed;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: VColors.field,
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: line.product['image_url'] != null
                  ? Image.network('${line.product['image_url']}',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                          Icons.inventory_2_outlined,
                          color: VColors.subtle,
                          size: 20))
                  : Icon(Icons.inventory_2_outlined,
                      color: VColors.subtle, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: Text('${line.product['name']}',
                              style: const TextStyle(fontSize: 15))),
                      InkWell(
                        onTap: onRemove,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 16, color: VColors.subtle),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      QtyStepper(quantity: line.quantity, changed: changed),
                      const Spacer(),
                      Text(money(line.total),
                          style:
                              const TextStyle(fontWeight: FontWeight.w900)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

