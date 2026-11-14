/// Moving a Bazel test's runfiles and paths to another machine, for
/// `ssh_test_runner`.
library;

/// Moves paths under this machine's runfiles, temp and test-log directories
/// to their copies on the host. Values are matched at the start and after a
/// `:` or `=`, where a path in a list or a flag begins.
class PathMap {
  PathMap(Map<String, String> roots)
    : _roots = roots.entries.toList()
        ..sort((a, b) => b.key.length.compareTo(a.key.length));

  final List<MapEntry<String, String>> _roots;

  String map(String value) {
    for (final MapEntry(key: local, value: remote) in _roots) {
      value = value.replaceAllMapped(
        RegExp('(^|[:=])${RegExp.escape(local)}(?=/|\$|:)'),
        (m) => '${m[1]}$remote',
      );
    }
    return value;
  }
}

/// One manifest line with its target moved under [root], or null for a blank
/// line. A line starting with a space has its key and target escaped (`\s`,
/// `\n`, `\b`); a key with no target is an empty file and stays as it is.
String? rewriteManifestLine(String line, String root) {
  if (line.isEmpty) return null;
  final escaped = line.startsWith(' ');
  final body = escaped ? line.substring(1) : line;
  final space = body.indexOf(' ');
  if (space < 0 || space == body.length - 1) return line;
  final key = body.substring(0, space);
  if (escaped && root.contains(RegExp(r'[ \n\\]'))) {
    throw ArgumentError.value(root, 'root', 'needs escaping in a manifest');
  }
  return '${escaped ? ' ' : ''}$key $root/$key';
}
