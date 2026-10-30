import 'package:bug_capsule_patch_gen/bug_capsule_patch_gen.dart';
import 'package:test/test.dart';

const header = "@Patchable('m.a')\n";

void main() {
  test('lowers a function with a helper', () {
    final u = Unit('''
int bonus(int tier) => tier > 2 ? 3 : 1;
$header int _\$points(int cents, int tier) {
  final base = cents ~/ 100;
  if (tier == 0) {
    return base;
  }
  return base * bonus(tier);
}
''');
    final src = u.lower(u.patchables.single);
    expect(src, contains('function bonus(tier: int): int'));
    expect(src, contains('(cents / 100)'));
    expect(src, contains('type Input = { cents: int, tier: int };'));
  });

  test('refuses what would change meaning or has no equivalent', () {
    for (final body in [
      'a / 2',
      'a % 2',
      'a.abs()',
      'a << 1',
      '[a].length',
      'print(a)',
      'DateTime.now().millisecond',
      'a is int ? 1 : 2',
      'throw a',
    ]) {
      final u = Unit('$header int _\$f(int a) => $body;');
      expect(() => u.lower(u.patchables.single), throwsA(isA<Unsupported>()), reason: body);
    }
  });

  test('refuses unsupported declarations', () {
    for (final s in [
      '$header Future<int> _\$f(int a) async => a;',
      '$header double _\$f(double a) => a;',
      '$header int _\$f(int a, {int b = 1}) => a;',
      '$header int _\$f<T>(int a) => a;',
      '$header int f(int a) => a;',
      '$header List<int> _\$f(int a) => [a];',
    ]) {
      expect(() => Unit(s), throwsA(isA<Unsupported>()), reason: s);
    }
  });

  test('loops and closures are refused', () {
    final u = Unit('$header int _\$f(int a) { for (var i = 0; i < a; i++) {} return a; }');
    expect(() => u.lower(u.patchables.single), throwsA(isA<Unsupported>()));
    final c = Unit('$header int _\$f(int a) { final g = () => a; return g(); }');
    expect(() => c.lower(c.patchables.single), throwsA(isA<Unsupported>()));
  });
}
