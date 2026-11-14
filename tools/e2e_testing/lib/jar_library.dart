/// Whether an app's classes hold one version of a Java library or a mix.
library;

import 'zip_entries.dart';

/// The classes of [app] in [library]'s packages that are not [library]'s
/// own, byte for byte: classes another version of the library put there.
///
/// Both are a jar's entries: [app] an app's deploy jar, the classes it
/// dexes, and [library] the jar of the one version the app should carry.
/// Gradle resolves one version of each library for an app; Bazel links
/// every jar that reaches the binary, so two versions of one library leave
/// the first jar's copy of each class they share and add the classes only
/// the other has: a mix neither version is.
List<String> classesNotFrom(List<ZipEntry> app, List<ZipEntry> library) {
  final own = {
    for (final entry in library)
      if (_isClass(entry.name)) entry.name: entry.crc32,
  };
  final packages = {for (final name in own.keys) _package(name)};
  return [
    for (final entry in app)
      if (_isClass(entry.name) &&
          packages.contains(_package(entry.name)) &&
          own[entry.name] != entry.crc32)
        entry.name,
  ];
}

/// A class of the jar's own, not a multi-release or module descriptor copy
/// under `META-INF/`.
bool _isClass(String name) =>
    name.endsWith('.class') && !name.startsWith('META-INF/');

String _package(String name) {
  final slash = name.lastIndexOf('/');
  return slash < 0 ? '' : name.substring(0, slash);
}
