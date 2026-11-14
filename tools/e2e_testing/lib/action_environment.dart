/// The environment Bazel gives an action it runs locally, for
/// `compile_fail_test` (compile_fail_runner.dart), which runs a target's
/// actions itself.
library;

/// The environment of an action whose own is [actionEnv], run with [tmp] as
/// its temporary directory, as Bazel's local spawn runner makes it.
///
/// On macOS and Linux that is [actionEnv] with `TMPDIR`. On Windows
/// ([windows]) Bazel names the temporary directory in `TMP` and `TEMP`, with
/// backslashes, and adds `SYSTEMROOT` and `SYSTEMDRIVE` from its own
/// environment ([host]) when the action has none: some programs, and the C
/// runtime of some, fail without them.
Map<String, String> actionEnvironment(
  Map<String, String> actionEnv, {
  required String tmp,
  required Map<String, String> host,
  required bool windows,
}) {
  if (!windows) return {...actionEnv, 'TMPDIR': tmp};
  final windowsTmp = tmp.replaceAll('/', r'\');
  return {
    for (final MapEntry(:key, :value) in actionEnv.entries)
      if (!_isAny(key, const ['TMP', 'TEMP'])) key: value,
    for (final name in const ['SYSTEMROOT', 'SYSTEMDRIVE'])
      if (!actionEnv.keys.any((key) => _isAny(key, [name])))
        if (_lookUp(host, name) case final value?) name: value,
    'TMP': windowsTmp,
    'TEMP': windowsTmp,
  };
}

/// Whether [key] is one of [names], as Windows compares variable names: without
/// regard to case.
bool _isAny(String key, List<String> names) =>
    names.contains(key.toUpperCase());

/// [name]'s value in [environment], whatever the case of its key there.
String? _lookUp(Map<String, String> environment, String name) {
  for (final MapEntry(:key, :value) in environment.entries) {
    if (key.toUpperCase() == name) return value;
  }
  return null;
}
