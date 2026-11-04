/// Checks that native libraries are ELF shared objects for an Android ABI.
///
/// Android's linker can only load ELF binaries built for the APK's ABI;
/// anything else (a host Mach-O dylib, a library of another architecture)
/// would crash the app at startup, so packaging fails instead. The ELF
/// machine type is the 2 bytes, little-endian, at offset 18 of the header.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// library that fails the check fails the build.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart validate_android_elf.dart --abi <abi> --machine <e_machine>
///       --stamp <file> <library>...
import 'dart:io';

/// The number of header bytes the check reads: through the 2-byte `e_machine`.
const headerLength = 20;

/// Why a library whose first bytes are [header] cannot be loaded for [abi],
/// or null when it can. [wantMachine] is the ELF machine the ABI requires and
/// [path] names the library in the message.
String? elfProblem({
  required List<int> header,
  required String path,
  required String abi,
  required int wantMachine,
}) {
  if (header.length < headerLength ||
      header[0] != 0x7f ||
      header[1] != 0x45 || // E
      header[2] != 0x4c || // L
      header[3] != 0x46) {
    // F
    return 'ERROR: $path is not an ELF binary. Android ($abi) cannot load it.';
  }
  final machine = header[18] | (header[19] << 8);
  if (machine != wantMachine) {
    return 'ERROR: $path has ELF machine $machine; $abi requires $wantMachine.';
  }
  return null;
}

/// The first [headerLength] bytes of the file at [path], or fewer if it is
/// shorter.
List<int> readHeader(String path) {
  final file = File(path).openSync();
  try {
    return file.readSync(headerLength);
  } finally {
    file.closeSync();
  }
}

/// Checks [args] (the command line) and returns the exit code.
int run(List<String> args) {
  String? abi;
  int? machine;
  String? stamp;
  final libraries = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--abi':
        abi = args[++i];
      case '--machine':
        machine = int.parse(args[++i]);
      case '--stamp':
        stamp = args[++i];
      default:
        libraries.add(args[i]);
    }
  }
  if (abi == null || machine == null || stamp == null) {
    stderr.writeln(
      'usage: validate_android_elf.dart --abi <abi> '
      '--machine <e_machine> --stamp <file> <library>...',
    );
    return 64;
  }
  var failed = false;
  for (final library in libraries) {
    final problem = elfProblem(
      header: readHeader(library),
      path: library,
      abi: abi,
      wantMachine: machine,
    );
    if (problem != null) {
      stderr.writeln(problem);
      failed = true;
    }
  }
  if (failed) {
    return 1;
  }
  File(stamp).writeAsStringSync('$abi\n');
  return 0;
}

void main(List<String> args) {
  exitCode = run(args);
}
