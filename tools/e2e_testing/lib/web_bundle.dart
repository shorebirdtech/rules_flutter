/// Reading the files of a built web bundle.
library;

import 'dart:io';

import 'bundle_check.dart';
import 'runfiles_paths.dart';

/// A bundle directory `flutter_web_app` or `flutter_web_bundle` produced,
/// found in the test's runfiles.
///
/// It reads the bundle's files and records a failure on [check], named for the
/// bundle, when one is missing; what the files must say stays in the test.
class WebBundle {
  /// A bundle at [path]. [label] names it in failures; it defaults to the
  /// directory's name.
  WebBundle(this.path, this.check, {String? label})
    : label = label ?? path.split(RegExp(r'[\\/]')).last;

  /// Finds the bundle at [workspacePath] in the test's runfiles
  /// (`app_wasm_web`, `custom_boot/inline_boot_web`).
  ///
  /// Exits 1 if there is no such directory.
  factory WebBundle.fromRunfiles(
    String workspacePath,
    BundleCheck check, {
    String? label,
  }) => WebBundle(
    requireRunfile(workspacePath, what: 'Web bundle'),
    check,
    label: label,
  );

  /// The bundle directory.
  final String path;

  /// Where checks are recorded.
  final BundleCheck check;

  /// What failures call this bundle.
  final String label;

  /// The file [name] in the bundle, which may not exist.
  File file(String name) => File('$path/$name');

  /// The text of [name], or null after failing the check if it is missing.
  String? read(String name) => requireFile(name)?.readAsStringSync();

  /// [name] if it exists, or null after failing the check.
  File? requireFile(String name) {
    final f = file(name);
    if (!f.existsSync()) {
      check.fail('$label: $name is missing from the bundle (${f.path})');
      return null;
    }
    return f;
  }

  /// The files anywhere under the bundle whose path ends with [suffix].
  List<File> filesEndingWith(String suffix) =>
      Directory(path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith(suffix))
          .toList();
}
