/// Checks that native libraries are ELF shared objects an Android device of an
/// ABI can load.
///
/// Android's linker can only load ELF binaries built for the APK's ABI;
/// anything else (a host Mach-O dylib, a library of another architecture)
/// would crash the app at startup, so packaging fails instead. The ELF
/// machine type is the 2 bytes, little-endian, at offset 18 of the header.
///
/// With `--min-load-align`, every library's `PT_LOAD` segments must be aligned
/// to at least that many bytes. A device with 16 KB pages refuses a library
/// linked for 4 KB ones, and nothing else says so before the app dies on
/// launch. And its `PT_GNU_RELRO` segment, if any, must end on a page of that
/// size or with the `PT_LOAD` segment that holds it, as Android's "Support
/// 16 KB page sizes" guide requires: the linker makes the whole page holding
/// the end of RELRO read-only, so writable data later in that page would
/// crash the app with SIGSEGV when written.
///
/// An app that does not need 16 KB support (one for a fleet of 4 KB devices,
/// or one Android 16 runs in page size compatibility mode) builds with
/// `--@rules_flutter//flutter:allow_4kb_aligned_native_libraries`, under which
/// the rule passes no `--min-load-align`; the message names it.
///
/// A `.zip` argument stands for the `.so` files inside it: rules_android
/// extracts the native libraries of an AAR into one.
///
/// On success the tool writes `--stamp`, which the build requires so that a
/// library that fails the check fails the build.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart validate_android_elf.dart --abi <abi> --machine <e_machine>
///       [--min-load-align <bytes>] --stamp <file> <library or zip>...
library;

import 'dart:io';
import 'dart:typed_data';

/// The number of header bytes the machine check reads: through the 2-byte
/// `e_machine`.
const headerLength = 20;

/// Why the library [bytes] cannot be loaded for [abi], or null when it can.
/// [wantMachine] is the ELF machine the ABI requires, [minLoadAlign] the
/// smallest `PT_LOAD` alignment a device of the ABI may need (null: not
/// checked), and [path] names the library in the message.
String? elfProblem({
  required List<int> bytes,
  required String path,
  required String abi,
  required int wantMachine,
  int? minLoadAlign,
}) {
  if (bytes.length < headerLength ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 || // E
      bytes[2] != 0x4c || // L
      bytes[3] != 0x46) {
    // F
    return 'ERROR: $path is not an ELF binary. Android ($abi) cannot load it.';
  }
  final machine = bytes[18] | (bytes[19] << 8);
  if (machine != wantMachine) {
    return 'ERROR: $path has ELF machine $machine; $abi requires $wantMachine.';
  }
  if (minLoadAlign == null) {
    return null;
  }
  final (align, error) = minLoadAlignment(Uint8List.fromList(bytes));
  if (error != null) {
    return 'ERROR: $path: $error.';
  }
  final kb = minLoadAlign ~/ 1024;
  // rules_android_ndk 0.1.5 links every arm64 library with
  // `-Wl,-z,max-page-size=4096`; upstream's efc0c191 fixes it.
  const toolchain =
      "Bazel's Android C/C++ toolchain links it. rules_android_ndk 0.1.5 links "
      'arm64 libraries for 4 KB pages: pin rules_android_ndk to a commit with '
      'its 16 KB fix (a `git_override` at efc0c191 or later, as the '
      'rules_flutter README\'s "16 KB memory pages" shows), or register a '
      'toolchain that links for 16 KB pages.';
  final prebuilt =
      "A prebuilt library, such as one inside a plugin's AAR, needs a release "
      'of it that supports $kb KB page sizes. An app that does not need them '
      '(one for devices with 4 KB pages only, or one that sets '
      '`android:pageSizeCompat` so that Android 16 runs it in page size '
      'compatibility mode) can build with '
      '--@rules_flutter//flutter:allow_4kb_aligned_native_libraries.';
  if (align! < minLoadAlign) {
    return 'ERROR: $path is linked for ${align ~/ 1024} KB pages (its '
        'PT_LOAD segments are aligned to $align bytes). An $abi device with '
        '$kb KB pages, as Android 15 devices can have, refuses to load it. '
        'Link it with `-Wl,-z,max-page-size=$minLoadAlign`, as NDK r28 and '
        'later do by default. $toolchain $prebuilt';
  }
  final relroEnd = misalignedRelroEnd(
    Uint8List.fromList(bytes),
    minLoadAlign,
  );
  if (relroEnd != null) {
    return 'ERROR: $path ends its GNU_RELRO segment at '
        '0x${relroEnd.toRadixString(16)}, inside a $kb KB page that holds '
        'writable data after it. An $abi device with $kb KB pages makes that '
        'whole page read-only once the library is relocated, and the app '
        'crashes with SIGSEGV when it writes the data. Link it with '
        '`-Wl,-z,max-page-size=$minLoadAlign` and '
        '`-Wl,-z,common-page-size=$minLoadAlign`, or with NDK r28 or later. '
        '$toolchain $prebuilt';
  }
  return null;
}

/// The end address of the `PT_GNU_RELRO` segment of the ELF file [bytes] when
/// a device with [pageSize] pages would make writable data read-only with it;
/// null when it would not.
///
/// It would not when there is no `PT_GNU_RELRO`, when RELRO ends on a page
/// boundary, or when it ends where the `PT_LOAD` segment holding it ends, so
/// that no writable data shares its last page: the three conditions of
/// Android's "Support 16 KB page sizes" guide. [bytes] has program headers
/// that [minLoadAlignment] has read.
int? misalignedRelroEnd(Uint8List bytes, int pageSize) {
  final segments = programHeaders(bytes);
  for (final relro in segments.where((s) => s.type == ptGnuRelro)) {
    final end = relro.vaddr + relro.memsz;
    if (end % pageSize == 0) continue;
    final holding = segments.where(
      (s) =>
          s.type == ptLoad &&
          s.vaddr <= relro.vaddr &&
          relro.vaddr < s.vaddr + s.memsz,
    );
    if (holding.any((load) => load.vaddr + load.memsz == end)) continue;
    return end;
  }
  return null;
}

const ptLoad = 1;
const ptGnuRelro = 0x6474e552;

/// One program header of an ELF file.
class ProgramHeader {
  ProgramHeader(this.type, this.vaddr, this.memsz, this.align);

  final int type;
  final int vaddr;
  final int memsz;
  final int align;
}

/// The program headers of the ELF file [bytes], whose header and program
/// header table [minLoadAlignment] has found readable.
List<ProgramHeader> programHeaders(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final is64 = bytes[4] == 2;
  final phoff = is64
      ? data.getUint64(0x20, Endian.little)
      : data.getUint32(0x1c, Endian.little);
  final phentsize = data.getUint16(is64 ? 0x36 : 0x2a, Endian.little);
  final phnum = data.getUint16(is64 ? 0x38 : 0x2c, Endian.little);
  int word(int at) => is64
      ? data.getUint64(at, Endian.little)
      : data.getUint32(at, Endian.little);
  final headers = <ProgramHeader>[];
  for (var i = 0; i < phnum; i++) {
    final at = phoff + i * phentsize;
    headers.add(
      ProgramHeader(
        data.getUint32(at, Endian.little),
        word(at + (is64 ? 0x10 : 0x08)), // p_vaddr
        word(at + (is64 ? 0x28 : 0x14)), // p_memsz
        word(at + (is64 ? 0x30 : 0x1c)), // p_align
      ),
    );
  }
  return headers;
}

/// The smallest `p_align` of the `PT_LOAD` segments of the ELF file [bytes],
/// or why it cannot be read.
(int?, String?) minLoadAlignment(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // e_ident[EI_CLASS]: 1 = ELF32, 2 = ELF64.
  final is64 = bytes[4] == 2;
  final headerSize = is64 ? 64 : 52;
  if (bytes.length < headerSize) {
    return (null, 'it is shorter than an ELF header');
  }
  final phoff = is64
      ? data.getUint64(0x20, Endian.little)
      : data.getUint32(0x1c, Endian.little);
  final phentsize = data.getUint16(is64 ? 0x36 : 0x2a, Endian.little);
  final phnum = data.getUint16(is64 ? 0x38 : 0x2c, Endian.little);
  if (phentsize < (is64 ? 0x38 : 0x20)) {
    return (null, 'its program header entries are too small to hold p_align');
  }
  if (phoff + phnum * phentsize > bytes.length) {
    return (null, 'its program headers run past the end of the file');
  }
  int? min;
  for (final segment in programHeaders(bytes)) {
    if (segment.type != ptLoad) continue;
    if (min == null || segment.align < min) min = segment.align;
  }
  if (min == null) {
    return (null, 'it has no PT_LOAD segments');
  }
  return (min, null);
}

const _endOfCentralDirectory = 0x06054b50;
const _centralHeader = 0x02014b50;
const _localHeader = 0x04034b50;

/// The `.so` entries of the zip archive [bytes], by name, uncompressed.
///
/// Throws [FormatException] for what is not a zip archive this can read.
Map<String, List<int>> zipLibraries(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // The end record is 22 bytes plus a comment of at most 65535.
  var end = -1;
  for (
    var at = bytes.length - 22;
    at >= 0 && at >= bytes.length - 65557;
    at--
  ) {
    if (data.getUint32(at, Endian.little) == _endOfCentralDirectory) {
      end = at;
      break;
    }
  }
  if (end < 0) {
    throw const FormatException('no zip end of central directory record');
  }
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final libraries = <String, List<int>>{};
  for (var i = 0; i < count; i++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != _centralHeader) {
      throw FormatException('no central directory header at $at');
    }
    final method = data.getUint16(at + 10, Endian.little);
    final compressedSize = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(bytes, at + 46, at + 46 + nameLength);
    at += 46 + nameLength + extraLength + commentLength;
    if (!name.endsWith('.so')) continue;
    if (local + 30 > bytes.length ||
        data.getUint32(local, Endian.little) != _localHeader) {
      throw FormatException('no local header for $name at $local');
    }
    final start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    final stored = Uint8List.sublistView(
      bytes,
      start,
      start + compressedSize,
    );
    libraries[name] = switch (method) {
      0 => stored,
      8 => ZLibDecoder(raw: true).convert(stored),
      _ => throw FormatException('$name uses compression method $method'),
    };
  }
  return libraries;
}

/// Checks [args] (the command line) and returns the exit code.
int run(List<String> args) {
  String? abi;
  int? machine;
  int? minLoadAlign;
  String? stamp;
  final inputs = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--abi':
        abi = args[++i];
      case '--machine':
        machine = int.parse(args[++i]);
      case '--min-load-align':
        minLoadAlign = int.parse(args[++i]);
      case '--stamp':
        stamp = args[++i];
      default:
        inputs.add(args[i]);
    }
  }
  if (abi == null || machine == null || stamp == null) {
    stderr.writeln(
      'usage: validate_android_elf.dart --abi <abi> --machine <e_machine> '
      '[--min-load-align <bytes>] --stamp <file> <library or zip>...',
    );
    return 64;
  }
  var failed = false;
  void check(String path, List<int> bytes) {
    final problem = elfProblem(
      bytes: bytes,
      path: path,
      abi: abi!,
      wantMachine: machine!,
      minLoadAlign: minLoadAlign,
    );
    if (problem != null) {
      stderr.writeln(problem);
      failed = true;
    }
  }

  for (final input in inputs) {
    final bytes = File(input).readAsBytesSync();
    if (input.endsWith('.zip')) {
      final Map<String, List<int>> libraries;
      try {
        libraries = zipLibraries(bytes);
      } on FormatException catch (e) {
        stderr.writeln('ERROR: $input: ${e.message}');
        failed = true;
        continue;
      }
      for (final MapEntry(key: name, value: library) in libraries.entries) {
        check('$input!/$name', library);
      }
    } else {
      check(input, bytes);
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
