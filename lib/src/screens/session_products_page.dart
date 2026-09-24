import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

/// "Tovarlar — [resourceName]" — adding products to a session's order while it's
/// still running. Every tap writes through to the order immediately (via
/// `add_order_item`/`remove_order_item`); there's no local cart to lose if
/// the window is closed, unlike the walk-in sale screen.
class SessionProductsPage extends StatefulWidget {
  const SessionProductsPage({
    super.key,
    required this.controller,
    required this.orderId,
    required this.resourceName,
  });

  final ClubController controller;
  final String orderId;
  final String resourceName;

  @override
  State<SessionProductsPage> createState() => _SessionProductsPageState();
}

class _SessionProductsPageState extends State<SessionProductsPage> {
  String category = 'ALL';
  String query = '';
  int revision = 0;
  final search = TextEditingController();
  final barcode = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    barcode.dispose();
    super.dispose();
  }

  Future<void> _scan(String code) async {
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
        await _add(Map<String, dynamic>.from(result['product'] as Map));
        barcode.clear();
      } else if (mounted) {
        showError(context, 'Tovar topilmadi: $code');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<_Data> _load() async {
    final repo = widget.controller.repository;
    final clubId = widget.controller.context!.clubId;
    final results = await Future.wait([
      repo.products(clubId),
      repo.productCategories(clubId),
      repo.orderJson(widget.orderId),
      repo.productSalesStats(clubId),
    ]);
    return _Data(
      (results[0] as List).cast<Map<String, dynamic>>(),
      (results[1] as List).cast<Map<String, dynamic>>(),
      results[2] as Map<String, dynamic>,
      results[3] as Map<String, num>,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: VColors.bg,
        body: SafeArea(
          child: AsyncPane<_Data>(
            future: _load(),
            builder: (context, data) {
              final items = ((data.order['order_items'] as List?) ?? [])
                  .cast<Map<String, dynamic>>()
                  .where((i) => i['kind'] == 'PRODUCT')
                  .toList();
              final productsTotal = items.fold<num>(
                  0, (sum, i) => sum + (i['total_price'] as num? ?? 0));

              final filtered = data.products
                  .where((p) => p['active'] == true)
                  .where((p) => category == 'ALL' ||
                      '${p['category_id']}' == category)
                  .where((p) =>
                      '${p['name']}'.toLowerCase().contains(query))
                  .toList()
                ..sort((a, b) {
                  final sa = data.sales['${a['id']}'] ?? 0;
                  final sb = data.sales['${b['id']}'] ?? 0;
                  if (sa != sb) return sb.compareTo(sa);
                  return '${a['name']}'.compareTo('${b['name']}');
                });

              return Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded)),
                      const SizedBox(width: 8),
                      Text('Tovarlar — ${widget.resourceName}',
                          style: Theme.of(context).textTheme.headlineMedium),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Tayyor'),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  SizedBox(
                                    width: 260,
                                    height: 46,
                                    child: TextField(
                                      controller: barcode,
                                      onSubmitted: _scan,
                                      style: const TextStyle(fontSize: 14),
                                      decoration: InputDecoration(
                                        hintText: 'Shtrix-kod',
                                        isDense: true,
                                        filled: true,
                                        fillColor: VColors.bg,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 12),
                                        border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide:
                                                BorderSide(color: VColors.line)),
                                        enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide:
                                                BorderSide(color: VColors.line)),
                                        focusedBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            borderSide: BorderSide(
                                                color: VColors.green,
                                                width: 1.5)),
                                        prefixIcon: Icon(
                                            Icons.qr_code_scanner_rounded,
                                            color: VColors.green, size: 19),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: SearchBox(
                                      hint: 'Tovar qidirish...',
                                      controller: search,
                                      dense: true,
                                      onChanged: (v) => setState(
                                          () => query = v.toLowerCase()),
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 76,
                                  child: ListView(
                                    scrollDirection: Axis.horizontal,
                                    children: [
                                      CategoryIconChip(
                                        label: 'Barchasi',
                                        isAll: true,
                                        selected: category == 'ALL',
                                        onTap: () =>
                                            setState(() => category = 'ALL'),
                                      ),
                                      for (final (i, c)
                                          in data.categories.indexed)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 8),
                                          child: CategoryIconChip(
                                            label: '${c['name']}',
                                            selected:
                                                category == '${c['id']}',
                                            icon: c['icon'] as String?,
                                            fallbackIndex: i,
                                            color: c['color'] != null
                                                ? Color(int.parse(
                                                    '${c['color']}'
                                                        .replaceFirst(
                                                            '#', 'FF'),
                                                    radix: 16))
                                                : null,
                                            onTap: () => setState(() =>
                                                category = '${c['id']}'),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Expanded(
                                  child: filtered.isEmpty
                                      ? const EmptyState(
                                          icon: Icons.inventory_2_outlined,
                                          title: 'Tovar topilmadi',
                                          subtitle:
                                              'Boshqa toifani tanlab ko\'ring')
                                      : LayoutBuilder(
                                          builder: (context, constraints) {
                                          final count =
                                              (constraints.maxWidth / 150)
                                                  .floor()
                                                  .clamp(3, 9);
                                          return GridView.builder(
                                          gridDelegate:
                                              SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: count,
                                            crossAxisSpacing: 10,
                                            mainAxisSpacing: 10,
                                            childAspectRatio: .72,
                                          ),
                                          itemCount: filtered.length,
                                          itemBuilder: (context, i) {
                                            final p = filtered[i];
                                            return ProductGridCard(
                                              product: p,
                                              onTap: () => _add(p),
                                            );
                                          },
                                        );
                                        }),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          SizedBox(
                            width: 320,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Ushbu hisobda',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 17)),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: items.isEmpty
                                      ? Text('Hali tovar qo\'shilmagan',
                                          style: TextStyle(
                                              color: VColors.subtle))
                                      : ListView.separated(
                                          itemCount: items.length,
                                          separatorBuilder: (_, __) =>
                                              const SizedBox(height: 12),
                                          itemBuilder: (context, i) =>
                                              _CartRow(
                                            item: items[i],
                                            onInc: () => _add({
                                              'id': items[i]['product_id'],
                                              'sale_price': null,
                                            }, silent: true),
                                            onDec: () => _dec(items[i]),
                                          ),
                                        ),
                                ),
                                const Divider(),
                                Row(children: [
                                  const Text('Tovarlar',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  const Spacer(),
                                  Text(money(productsTotal),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 17)),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

  Future<void> _add(Map<String, dynamic> product, {bool silent = false}) async {
    try {
      await widget.controller.repository
          .addOrderItem(widget.orderId, '${product['id']}', 1);
      setState(() => revision++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _dec(Map<String, dynamic> item) async {
    try {
      await widget.controller.repository.removeOrderItem('${item['id']}', 1);
      setState(() => revision++);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

class _Data {
  _Data(this.products, this.categories, this.order, this.sales);
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> categories;
  final Map<String, dynamic> order;
  final Map<String, num> sales;
}

class _CartRow extends StatelessWidget {
  const _CartRow({required this.item, required this.onInc, required this.onDec});
  final Map<String, dynamic> item;
  final VoidCallback onInc;
  final VoidCallback onDec;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text('${item['description']}',
                    style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(money(item['total_price']),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            QtyStepper(
              quantity: (item['quantity'] as num?) ?? 1,
              changed: (delta) => delta > 0 ? onInc() : onDec(),
            ),
            const SizedBox(width: 10),
            Text('× ${money(item['unit_price'])}',
                style: TextStyle(color: VColors.subtle, fontSize: 13)),
          ]),
        ],
      );
}
