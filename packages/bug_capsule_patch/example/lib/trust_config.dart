/// An explicit malformed root list must not silently select the demo trust root.
List<String> labTrustRoots(Map<String, Object?>? config, String fallback) {
  if (config != null && config.containsKey('trustRoots')) {
    final roots = config['trustRoots'];
    if (roots is! List || roots.isEmpty ||
        roots.any((r) => r is! String || !r.startsWith('bcpk.v1.'))) {
      throw const FormatException('trustRoots must be a nonempty public root list');
    }
    return roots.cast<String>();
  }
  return [config?['trustRoot'] as String? ?? fallback];
}
