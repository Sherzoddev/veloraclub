/// Mixed payment: one check paid with several methods at once (part cash,
/// part card, part transfer). The cashier types an amount per method; the
/// check can be paid only when the amounts add up to the total.
library;

/// One method's share of a check.
class SplitLine {
  const SplitLine(this.methodId, this.name, this.amount);
  final String methodId;
  final String name;
  final int amount;
}

class PaymentSplit {
  const PaymentSplit._();

  /// "50 000", "50000", "" -> 50000 / 0. Anything that is not a digit is
  /// ignored (spaces, non-breaking spaces from copied numbers).
  static int parse(String text) {
    final digits = text.replaceAll(RegExp(r'\D'), '');
    return digits.isEmpty ? 0 : int.tryParse(digits) ?? 0;
  }

  static int sum(Iterable<String> texts) =>
      texts.fold(0, (a, t) => a + parse(t));

  /// What is still to be entered: positive = short, negative = too much.
  static int remaining(int total, Iterable<String> texts) => total - sum(texts);

  /// The lines to send: methods with an amount above zero, in the order the
  /// club lists its methods. [texts] is methodId -> what was typed.
  static List<SplitLine> lines(
      List<Map<String, dynamic>> methods, Map<String, String> texts) {
    return [
      for (final m in methods)
        if (parse(texts['${m['id']}'] ?? '') > 0)
          SplitLine(
              '${m['id']}', '${m['name']}', parse(texts['${m['id']}'] ?? '')),
    ];
  }

  /// The check can be paid: something to pay and the amounts match exactly.
  static bool isComplete(int total, Map<String, String> texts) =>
      total > 0 && remaining(total, texts.values) == 0;

  /// "Наличные 50 000 so'm, Uzcard 30 000 so'm" for the receipt.
  static String label(List<SplitLine> lines, String Function(int) format) =>
      lines.map((l) => '${l.name} ${format(l.amount)}').join(', ');

  /// How much to put into one field so the check balances: the total minus
  /// everything typed in the other fields (never negative).
  static int fillFor(String methodId, int total, Map<String, String> texts) {
    var others = 0;
    texts.forEach((id, t) {
      if (id != methodId) others += parse(t);
    });
    final rest = total - others;
    return rest < 0 ? 0 : rest;
  }
}
