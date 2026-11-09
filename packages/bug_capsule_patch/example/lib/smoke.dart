/// The lab's own smoke check on the price it is about to show. It recomputes
/// the expected subtotal from the cart (the product rule: lines of 10+ units
/// get 5% off, half-even) and checks the discount and total against it. It is
/// independent of the patch's code. Returns why the result is not acceptable,
/// or null. A patched result that fails is never marked healthy, so a signed
/// but wrong patch stays in probation and the engine rolls it back.
///
/// Amounts are parsed with a bound (at most 9 whole digits) before any
/// arithmetic, so a hostile or huge value is refused instead of overflowing.
String? smokeFailure({
  required List<({int qty, int unitCents})> lines,
  required int couponPercent,
  required String subtotal,
  required String discount,
  required String total,
  required String label,
}) {
  final s = _cents(subtotal), d = _cents(discount), t = _cents(total);
  if (s == null || d == null || t == null) return 'unparseable_amounts';
  if (s != expectedSubtotalCents(lines)) return 'subtotal_mismatch';
  final percent = couponPercent.clamp(0, 50);
  if (d != _halfEven(s * percent, 100)) return 'discount_mismatch';
  if (t != s - d) return 'total_mismatch';
  if (label.isEmpty) return 'empty_label';
  return null;
}

/// Lab carts are small (quantities and prices well under 10^6), so this
/// cannot overflow.
int expectedSubtotalCents(List<({int qty, int unitCents})> lines) {
  var sum = 0;
  for (final l in lines) {
    final gross = l.unitCents * l.qty;
    sum += l.qty >= 10 ? _halfEven(gross * 95, 100) : gross;
  }
  return sum;
}

final _amount = RegExp(r'^-?(0|[1-9][0-9]{0,8})\.[0-9]{2}$');

int? _cents(String text) {
  if (!_amount.hasMatch(text)) return null;
  final negative = text.startsWith('-');
  final parts = (negative ? text.substring(1) : text).split('.');
  final v = int.parse(parts[0]) * 100 + int.parse(parts[1]);
  return negative ? -v : v;
}

int _halfEven(int n, int d) {
  final q = n ~/ d, r = n % d;
  return r * 2 > d || (r * 2 == d && q.isOdd) ? q + 1 : q;
}
