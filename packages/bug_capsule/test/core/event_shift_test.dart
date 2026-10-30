import 'package:bug_capsule/src/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a screenshot keeps capturedAtT at or before t after the anchor shift', () {
    const event = BugCapsuleEvent(
      seq: 1,
      t: 6998,
      type: 'screenshot',
      data: {'schema': 1, 'capturedAtT': 6998},
    );

    final shifted = event.shift(1181);

    expect(shifted.t, 5817);
    expect(shifted.data['capturedAtT'], 5817);
    expect(shifted.data['schema'], 1);
    expect(event.data['capturedAtT'], 6998);
  });

  test('other events keep their data', () {
    const data = {'id': 'cart.checkout'};
    const event = BugCapsuleEvent(seq: 2, t: 100, type: 'action', data: data);

    expect(identical(event.shift(40).data, data), isTrue);
  });
}
