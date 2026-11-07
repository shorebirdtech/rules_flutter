/// Verifies that an Apple plugin is built as its `Package.swift` says.
///
/// `flutter_qjs_next` 1.5.2 compiles QuickJS's C sources, and its manifest
/// sets `CONFIG_VERSION` to `"2026-06-04"`, which QuickJS prints in its memory
/// report, and, in debug builds only, `DUMP_LEAKS`, which compiles in the leak
/// report. The simulator build is a debug build, so the app carries the C
/// code, the version string and the leak report.
library;

import 'dart:convert';

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'swiftpm_plugins_app.ipa',
    prefix: 'ios_swiftpm_plugins_test',
  );
  try {
    final check = bundle.check;
    // A debug build may put the runner's code in a sibling `.debug.dylib`, so
    // look in every Mach-O file at the bundle root.
    final binaries = bundle.rootFiles;
    bool anyContains(String text) {
      final needle = ascii.encode(text);
      return binaries.any((f) => _contains(f.readAsBytesSync(), needle));
    }

    check
      ..expect(
        "a binary in the bundle carries QuickJS's C code",
        condition: binaries.any(
          (f) => MachO(f.path).hasSymbolContaining('JS_NewRuntime'),
        ),
      )
      ..expect(
        'QuickJS was compiled with CONFIG_VERSION from Package.swift',
        condition: anyContains('QuickJS memory usage -- 2026-06-04 version'),
      )
      ..expect(
        "QuickJS was compiled with Package.swift's debug-only DUMP_LEAKS",
        condition: anyContains('string leakage'),
      );
    bundle.finish('All Swift package plugin checks passed.');
  } finally {
    bundle.dispose();
  }
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
