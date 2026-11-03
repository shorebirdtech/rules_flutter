/// Looking for symbols in a built Mach-O binary.
library;

import 'dart:io';

/// A Mach-O binary, queried with `nm`.
class MachO {
  /// The binary at [path].
  const MachO(this.path);

  /// The binary's file path.
  final String path;

  /// Whether the binary lists a symbol containing [name]. Swift names are
  /// mangled around the type name, so this matches by substring.
  ///
  /// A file `nm` cannot read, which is any file that is not a Mach-O binary,
  /// has no symbols.
  bool hasSymbolContaining(String name) {
    final result = Process.runSync('nm', [path]);
    return result.exitCode == 0 && result.stdout.toString().contains(name);
  }
}
