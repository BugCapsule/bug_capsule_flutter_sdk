import 'package:bug_capsule_patch_example/smoke.dart';
import 'package:flutter_test/flutter_test.dart';

const lab = [(qty: 2, unitCents: 1999), (qty: 10, unitCents: 300)];

String? check(
  String s,
  String d,
  String t, {
  int percent = 20,
  String label = 'PATCHED 20%',
  List<({int qty, int unitCents})> lines = lab,
}) => smokeFailure(
  lines: lines,
  couponPercent: percent,
  subtotal: s,
  discount: d,
  total: t,
  label: label,
);

void main() {
  test('the signed fix for the lab cart passes', () {
    expect(expectedSubtotalCents(lab), 6848);
    expect(check('68.48', '13.70', '54.78'), isNull);
  });
  test('the shipped bug fails', () {
    expect(check('69.98', '1399.60', '-1329.62'), 'subtotal_mismatch');
  });
  test('a consistent but wrong result fails', () {
    expect(check('1.00', '0.20', '0.80'), 'subtotal_mismatch');
  });
  test('a wrong total fails', () {
    expect(check('68.48', '13.70', '55.78'), 'total_mismatch');
  });
  test('a wrong percentage fails', () {
    expect(check('68.48', '6.85', '61.63'), 'discount_mismatch');
  });
  test('huge values are refused without overflow', () {
    expect(
      check('99999999999999999999.00', '0.00', '0.00'),
      'unparseable_amounts',
    );
    expect(
      check('9223372036854775807.00', '0.00', '0.00'),
      'unparseable_amounts',
    );
    expect(
      check('999999999.99', '199999999.99', '800000000.00'),
      'subtotal_mismatch',
    );
  });
  test('half-even rounding and the 50% cap', () {
    expect(
      check(
        '0.25',
        '0.12',
        '0.13',
        percent: 50,
        lines: [(qty: 1, unitCents: 25)],
      ),
      isNull,
    );
    expect(
      check(
        '10.00',
        '5.00',
        '5.00',
        percent: 80,
        lines: [(qty: 1, unitCents: 1000)],
      ),
      isNull,
    );
  });
  test('malformed values and an empty label fail', () {
    expect(check('68.4', '13.70', '54.78'), 'unparseable_amounts');
    expect(check('068.48', '13.70', '54.78'), 'unparseable_amounts');
    expect(check('68.48', '13.70', '54.78', label: ''), 'empty_label');
  });
}
