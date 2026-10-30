import 'package:bug_capsule_patch/bug_capsule_patch.dart';

part 'loyalty.patch.g.dart';

int tierMultiplier(int tier) => tier > 2 ? 3 : 1;

// The bug: points should be earned per 100 cents, and tier 2 earns double.
@Patchable('pricing.points')
int _$loyaltyPoints(int cents, int tier) {
  final base = cents ~/ 1000;
  return base * tierMultiplier(tier);
}
