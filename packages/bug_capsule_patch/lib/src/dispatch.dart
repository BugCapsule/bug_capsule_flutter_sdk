import 'runtime.dart';

/// Marks a top-level function, named `_$name`, as patchable. `bcpatch_gen`
/// generates the public `name` that dispatches to the installed patch.
final class Patchable {
  const Patchable(this.id);
  final String id;
}

/// Connects generated stubs to the runtime. Until [install] runs, or when no
/// patch applies, every stub calls the compiled base function.
abstract final class PatchDispatch {
  static BugCapsulePatch? _patch;

  static void install(BugCapsulePatch patch) => _patch = patch;

  static O call<O>(PatchModule<Map<String, Object?>, O> module, Map<String, Object?> input) {
    final patch = _patch;
    return patch == null ? module.fallback(input) : patch.call(module, input).value;
  }
}
