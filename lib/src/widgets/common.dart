import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils.dart';

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!,
                    style: TextStyle(color: VColors.muted, fontSize: 15)),
              ],
            ],
          ),
        ),
        ...actions.map((e) => Padding(
              padding: const EdgeInsets.only(left: 10),
              child: e,
            )),
      ],
    );
  }
}

class SearchBox extends StatelessWidget {
  const SearchBox({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.width,
    this.autofocus = false,
    this.dense = false,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final double? width;
  final bool autofocus;

  /// Compact, dark-filled variant (thin border instead of the light field
  /// fill) used on screens like Sotuv where the default input look reads
  /// too light against the surrounding dark cards.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: dense ? 46 : 58,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        autofocus: autofocus,
        style: dense ? const TextStyle(fontSize: 14) : null,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(Icons.search_rounded,
              color: VColors.ink, size: dense ? 19 : 24),
          isDense: dense,
          filled: dense ? true : null,
          fillColor: dense ? VColors.bg : null,
          contentPadding: dense
              ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
              : null,
          border: dense
              ? OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: VColors.line))
              : null,
          enabledBorder: dense
              ? OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: VColors.line))
              : null,
          focusedBorder: dense
              ? OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: VColors.green, width: 1.5))
              : null,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: VColors.field,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 40, color: VColors.subtle),
          ),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(subtitle, style: TextStyle(color: VColors.subtle)),
        ],
      ),
    );
  }
}

class LoadingPane extends StatelessWidget {
  const LoadingPane({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

/// Renders [future] via [builder], but — unlike a bare `FutureBuilder` — a
/// *new* future (e.g. after `controller.refresh()` recreates it on rebuild)
/// keeps showing the last good data while it loads in the background instead
/// of flashing back to a spinner. Only the very first load, or a load that
/// fails before any data has ever arrived, shows [LoadingPane]/the error
/// card. This is what makes routine actions (pause, add to cart, pay) feel
/// instant instead of re-loading the whole screen every time.
class AsyncPane<T> extends StatefulWidget {
  const AsyncPane({super.key, required this.future, required this.builder});

  final Future<T> future;
  final Widget Function(BuildContext, T) builder;

  @override
  State<AsyncPane<T>> createState() => _AsyncPaneState<T>();
}

class _AsyncPaneState<T> extends State<AsyncPane<T>> {
  T? _data;
  bool _hasData = false;
  Object? _error;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _attach(widget.future);
  }

  @override
  void didUpdateWidget(covariant AsyncPane<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.future, oldWidget.future)) {
      _attach(widget.future);
    }
  }

  void _attach(Future<T> future) {
    final generation = ++_requestGeneration;
    future.then((value) {
      // Realtime can cause several refreshes while one transaction is being
      // committed. Never let an older, slower request overwrite the newest
      // snapshot (for example showing a just-started table as free again).
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _data = value;
        _hasData = true;
        _error = null;
      });
    }, onError: (Object e) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = e;
        if (!_hasData) _data = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_hasData) return widget.builder(context, _data as T);
    if (_error != null) {
      return Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded, size: 38, color: VColors.red),
                const SizedBox(height: 12),
                Text('Ma\'lumot yuklanmadi',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                SizedBox(
                  width: 520,
                  child: Text('$_error',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: VColors.muted)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const LoadingPane();
  }
}

/// Compact horizontal-scroll category filter chip — shared by every product
/// grid (Sotuv, session product picker) so they stay visually identical.
class CategoryChip extends StatelessWidget {
  const CategoryChip(
      {super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? VColors.green : VColors.field,
            borderRadius: BorderRadius.circular(9),
            border:
                Border.all(color: selected ? VColors.green : VColors.line),
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                    color: selected ? Colors.black87 : VColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      );
}

/// Compact bordered [-|qty|+] group — the qty-in-cart control shared by the
/// Sotuv cart and the in-session product picker. Shows a trash icon instead
/// of "-" once quantity would drop to zero, and formats a whole-number
/// quantity ("3") instead of the raw numeric ("3.0") a Postgres `numeric`
/// column decodes to.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.quantity, required this.changed});
  final num quantity;
  final ValueChanged<int> changed;

  String get _label =>
      quantity % 1 == 0 ? quantity.toInt().toString() : quantity.toString();

  @override
  Widget build(BuildContext context) => Container(
        height: 30,
        decoration: BoxDecoration(
          border: Border.all(color: VColors.line),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _btn(
                quantity <= 1
                    ? Icons.delete_outline_rounded
                    : Icons.remove_rounded,
                () => changed(-1)),
            Container(width: 1, height: 30, color: VColors.line),
            SizedBox(
              width: 32,
              child: Center(
                child: Text(_label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 13)),
              ),
            ),
            Container(width: 1, height: 30, color: VColors.line),
            _btn(Icons.add_rounded, () => changed(1)),
          ],
        ),
      );

  Widget _btn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child:
            SizedBox(width: 30, height: 30, child: Icon(icon, size: 15)),
      );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.foreground});

  final String text;
  final Color? color;
  final Color? foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
            color: color ?? VColors.greenSoft,
            borderRadius: BorderRadius.circular(10)),
        child: Text(text,
            style: TextStyle(
                color: foreground ?? VColors.green,
                fontWeight: FontWeight.w800)),
      );
}

class VCard extends StatelessWidget {
  const VCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(padding: padding, child: child),
      );
}

/// Fallback palette for categories that have no color set in the database —
/// picked by index so the row still reads as colorful/distinct instead of
/// every uncolored category collapsing to the same green badge.
const kCategoryFallbackColors = [
  Color(0xFF3B82F6),
  Color(0xFF22C55E),
  Color(0xFFA855F7),
  Color(0xFFEC4899),
  Color(0xFFF59E0B),
  Color(0xFF14B8A6),
  Color(0xFFEF4444),
];

/// A category filter tile — used above both the walk-in sale grid and the
/// "add products to a table" grid so the two pickers look and behave the
/// same. Mirrors the club's other (web-based) POS: "All" is a solid brand
/// pill; every other category is a bordered card with a round colored badge
/// on top and the name below, active state picked out by a brand border +
/// soft tinted background rather than just a ring.
class CategoryIconChip extends StatelessWidget {
  const CategoryIconChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.color,
    this.isAll = false,
    this.fallbackIndex = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? icon;
  final Color? color;
  final bool isAll;
  final int fallbackIndex;

  @override
  Widget build(BuildContext context) {
    if (isAll) {
      // Same tile shell as every other category (width 76, 10/6 padding) but
      // with no icon badge above the label -- so unlike the icon tiles it
      // sizes to its text height instead of matching their taller box.
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 76,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: VColors.green,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      );
    }
    final c = color ??
        kCategoryFallbackColors[
            fallbackIndex % kCategoryFallbackColors.length];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: .1) : VColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? c : VColors.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              child: icon != null && icon!.isNotEmpty
                  ? Text(icon!, style: const TextStyle(fontSize: 14))
                  : const Icon(Icons.fastfood_outlined,
                      color: Colors.white, size: 14),
            ),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? VColors.ink
                        : VColors.ink.withValues(alpha: .82))),
          ],
        ),
      ),
    );
  }
}

/// A product tile for the sale grids — photo on top at a fixed 3:2 ratio
/// (contain-fit, so the whole item stays visible instead of a cover-crop
/// clipping it), name/price/stock stacked as separate lines underneath.
/// Mirrors the club's other (web-based) POS product card 1:1, down to the
/// price being plain ink rather than colored and stock status color-coded
/// by how low it is, not just in/out.
class ProductGridCard extends StatelessWidget {
  const ProductGridCard({
    super.key,
    required this.product,
    required this.onTap,
    this.unitLabel = 'dona',
  });

  final Map<String, dynamic> product;
  final VoidCallback? onTap;
  final String unitLabel;

  @override
  Widget build(BuildContext context) {
    final cat = product['product_categories'];
    final catColor = cat is Map && cat['color'] != null
        ? Color(int.parse('${cat['color']}'.replaceFirst('#', 'FF'), radix: 16))
        : null;
    final stock = (product['stock_quantity'] as num?) ?? 0;
    final imageUrl = product['image_url'] as String?;
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final statusColor = stock <= 0
        ? VColors.red
        : stock <= 5
            ? VColors.orange
            : VColors.green;
    final statusText = stock <= 0
        ? 'Mavjud emas'
        : '${stock == stock.roundToDouble() ? stock.toInt() : stock} ${product['unit'] ?? unitLabel}';
    return Opacity(
      opacity: onTap == null ? .5 : 1,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: VColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.center,
                  color: !hasImage && catColor != null
                      ? catColor.withValues(alpha: .15)
                      : VColors.field,
                  padding: const EdgeInsets.all(6),
                  child: hasImage
                      ? Image.network(imageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                              Icons.inventory_2_outlined,
                              color: catColor ?? VColors.subtle,
                              size: 32),
                        )
                      : (cat is Map &&
                              cat['icon'] != null &&
                              '${cat['icon']}'.isNotEmpty
                          ? Text('${cat['icon']}',
                              style: const TextStyle(fontSize: 34))
                          : Icon(Icons.inventory_2_outlined,
                              color: catColor ?? VColors.subtle, size: 32)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${product['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14.5,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                            color: VColors.ink)),
                    const SizedBox(height: 3),
                    Text(money(product['sale_price']),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: VColors.ink)),
                    const SizedBox(height: 3),
                    Text(statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
