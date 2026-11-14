/// Build-time work on the Linux runtime integration tests run in: the Debian
/// packages that hold the X server, GTK, Mesa and what headless Chrome links.
///
/// `check`: every ELF file given asks no more of the host's C and C++ runtime
/// than the floor, and every library it names (`DT_NEEDED`) is one the runtime
/// or the host's C and C++ runtime has. Writes `--stamp` when both hold, so that
/// a pinned package that would fail on a supported host fails the build, naming
/// the file and what it asks for.
///
/// `patch-xvfb`: a copy of `Xvfb` that runs `xkbcomp` from `PATH` rather than
/// from `/usr/bin`, which is where Debian's build puts it and the host has
/// none of. The X server keeps that directory as the string `XKB_BIN_DIRECTORY`
/// and puts no separator after it when it is empty, so emptying it is enough.
///
/// The tool has no package dependencies and runs with the bare Dart SDK, so it
/// runs on any host.
///
/// Usage:
///   dart linux_runtime.dart check --stamp <file> --floor <NAME>=<version>...
///       --host-library <soname>... [--provider <file>...] <file>...
///   dart linux_runtime.dart patch-xvfb <in> <out>
///
/// An argument `@<file>` is replaced by the lines of that file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What an ELF file says about the libraries it loads.
class ElfDynamicInfo {
  /// Facts read by [readElfDynamicInfo].
  const ElfDynamicInfo({
    required this.soname,
    required this.needed,
    required this.versionsNeeded,
  });

  /// `DT_SONAME`, or null for an executable or a library without one.
  final String? soname;

  /// `DT_NEEDED`: the libraries the dynamic loader loads for it.
  final List<String> needed;

  /// From `.gnu.version_r`: for each library, the symbol versions it must
  /// define (`libc.so.6` → `GLIBC_2.34`, ...).
  final Map<String, List<String>> versionsNeeded;
}

/// Whether [bytes] start as an ELF file does.
bool isElf(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x7f &&
    bytes[1] == 0x45 &&
    bytes[2] == 0x4c &&
    bytes[3] == 0x46;

/// Reads the dynamic section and the version needs of the 64-bit
/// little-endian ELF file [bytes]. Throws a [FormatException] for any other
/// ELF: the runtime is for x86_64 and arm64 only.
ElfDynamicInfo readElfDynamicInfo(Uint8List bytes) {
  if (!isElf(bytes)) throw const FormatException('not an ELF file');
  if (bytes[4] != 2 || bytes[5] != 1) {
    throw const FormatException('not a 64-bit little-endian ELF file');
  }
  final data = ByteData.sublistView(bytes);
  int u16(int at) => data.getUint16(at, Endian.little);
  int u32(int at) => data.getUint32(at, Endian.little);
  int u64(int at) => data.getUint64(at, Endian.little);

  final shoff = u64(0x28);
  final shentsize = u16(0x3a);
  final shnum = u16(0x3c);
  if (shoff == 0 || shnum == 0) {
    return const ElfDynamicInfo(soname: null, needed: [], versionsNeeded: {});
  }
  ({int type, int offset, int size, int link}) section(int i) {
    final at = shoff + i * shentsize;
    return (
      type: u32(at + 4),
      offset: u64(at + 0x18),
      size: u64(at + 0x20),
      link: u32(at + 0x28),
    );
  }

  String string(int table, int at) {
    final start = section(table).offset + at;
    var end = start;
    while (bytes[end] != 0) {
      end++;
    }
    return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  }

  const shtDynamic = 6;
  const shtGnuVerneed = 0x6ffffffe;
  const dtNeeded = 1;
  const dtSoname = 14;

  String? soname;
  final needed = <String>[];
  final versionsNeeded = <String, List<String>>{};
  for (var i = 0; i < shnum; i++) {
    final s = section(i);
    if (s.type == shtDynamic) {
      for (var at = s.offset; at + 16 <= s.offset + s.size; at += 16) {
        final tag = u64(at);
        if (tag == 0) break;
        if (tag == dtNeeded) needed.add(string(s.link, u64(at + 8)));
        if (tag == dtSoname) soname = string(s.link, u64(at + 8));
      }
    } else if (s.type == shtGnuVerneed) {
      var need = s.offset;
      while (true) {
        final count = u16(need + 2);
        final file = string(s.link, u32(need + 4));
        var aux = need + u32(need + 8);
        final versions = versionsNeeded[file] ??= [];
        for (var j = 0; j < count; j++) {
          versions.add(string(s.link, u32(aux + 8)));
          final next = u32(aux + 12);
          if (next == 0) break;
          aux += next;
        }
        final next = u32(need + 12);
        if (next == 0) break;
        need += next;
      }
    }
  }
  return ElfDynamicInfo(
    soname: soname,
    needed: needed,
    versionsNeeded: versionsNeeded,
  );
}

/// The versions `1.3.15` as numbers, for comparing.
List<int> _numbers(String version) => [
  for (final part in version.split('.')) int.tryParse(part) ?? -1,
];

int _compareVersions(String a, String b) {
  final x = _numbers(a);
  final y = _numbers(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// What is wrong with the file at [path], whose facts are [info]: each symbol
/// version it asks of a host library ([hostLibraries]) that is past [floor]
/// or not a version the floor names, and each library it needs that is in
/// neither [hostLibraries] nor [provided].
List<String> elfProblems(
  String path,
  ElfDynamicInfo info, {
  required Map<String, String> floor,
  required Set<String> hostLibraries,
  required Set<String> provided,
}) {
  final problems = <String>[];
  for (final library in info.needed) {
    if (!hostLibraries.contains(library) && !provided.contains(library)) {
      problems.add('$path needs $library, which the runtime does not have');
    }
  }
  for (final MapEntry(key: library, value: versions)
      in info.versionsNeeded.entries) {
    if (!hostLibraries.contains(library)) continue;
    for (final version in versions) {
      final underscore = version.indexOf('_');
      final name = underscore < 0 ? version : version.substring(0, underscore);
      final number = underscore < 0 ? '' : version.substring(underscore + 1);
      final limit = floor[name];
      if (limit == null || number.isEmpty || _numbers(number).contains(-1)) {
        problems.add(
          '$path asks $library for $version, which is no version of '
          '${floor.keys.join(', ')} the host floor names',
        );
      } else if (_compareVersions(number, limit) > 0) {
        problems.add(
          '$path asks $library for $version, newer than the host floor '
          '${name}_$limit',
        );
      }
    }
  }
  return problems;
}

/// Empties the string `/usr/bin` that [xvfb] holds once, by zeroing its first
/// byte. Throws a [StateError] when the string is not there exactly once,
/// since a guess would patch the wrong bytes.
Uint8List patchXvfb(Uint8List xvfb) {
  final needle = ascii.encode('\x00/usr/bin\x00');
  final found = <int>[];
  for (var i = 0; i + needle.length <= xvfb.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (xvfb[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) found.add(i + 1);
  }
  if (found.length != 1) {
    throw StateError(
      'Xvfb holds the string "/usr/bin" ${found.length} times, not once, so '
      'which is the directory it runs xkbcomp from is not known',
    );
  }
  return Uint8List.fromList(xvfb)..[found.single] = 0;
}

List<String> _expand(List<String> args) => [
  for (final arg in args)
    if (arg.startsWith('@'))
      ...File(arg.substring(1)).readAsLinesSync().where((l) => l.isNotEmpty)
    else
      arg,
];

int _check(List<String> args) {
  String? stamp;
  final floor = <String, String>{};
  final hostLibraries = <String>{};
  final providers = <String>[];
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String value() {
      if (i + 1 >= args.length) throw FormatException('$arg needs a value');
      return args[++i];
    }

    switch (arg) {
      case '--stamp':
        stamp = value();
      case '--floor':
        final entry = value();
        final equals = entry.indexOf('=');
        if (equals < 0) throw FormatException('--floor $entry is not NAME=V');
        floor[entry.substring(0, equals)] = entry.substring(equals + 1);
      case '--host-library':
        hostLibraries.add(value());
      case '--provider':
        providers.add(value());
      default:
        files.add(arg);
    }
  }
  if (stamp == null || floor.isEmpty) {
    throw const FormatException('check needs --stamp and --floor');
  }

  final infos = <String, ElfDynamicInfo>{};
  final provided = <String>{};
  void read(String path, {required bool checked}) {
    final file = File(path);
    if (FileSystemEntity.isDirectorySync(path) || !file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    if (!isElf(bytes)) return;
    final info = readElfDynamicInfo(bytes);
    // A library is found by the name it is installed as (the loader's search
    // reads file names), whatever its `DT_SONAME` says.
    provided.add(path.substring(path.lastIndexOf('/') + 1));
    if (info.soname case final soname?) provided.add(soname);
    if (checked) infos[path] = info;
  }

  for (final path in providers) {
    read(path, checked: false);
  }
  for (final path in files) {
    read(path, checked: true);
  }
  final problems = [
    for (final MapEntry(:key, :value) in infos.entries)
      ...elfProblems(
        key,
        value,
        floor: floor,
        hostLibraries: hostLibraries,
        provided: provided,
      ),
  ];
  if (problems.isNotEmpty) {
    stderr.writeln(
      'The Linux runtime asks more of the host than it may '
      '(${floor.entries.map((e) => '${e.key}_${e.value}').join(', ')}, the '
      'oldest host supported), or names a library it does not have:',
    );
    for (final problem in problems) {
      stderr.writeln('  $problem');
    }
    return 1;
  }
  File(stamp).writeAsStringSync('${infos.length} ELF files checked\n');
  return 0;
}

int run(List<String> rawArgs) {
  final args = _expand(rawArgs);
  if (args.isEmpty) {
    stderr.writeln('usage: linux_runtime.dart check|patch-xvfb ...');
    return 64;
  }
  switch (args.first) {
    case 'check':
      return _check(args.sublist(1));
    case 'patch-xvfb':
      if (args.length != 3) {
        stderr.writeln('usage: linux_runtime.dart patch-xvfb <in> <out>');
        return 64;
      }
      final out = File(args[2]);
      out.writeAsBytesSync(patchXvfb(File(args[1]).readAsBytesSync()));
      return 0;
    default:
      stderr.writeln('unknown command ${args.first}');
      return 64;
  }
}

void main(List<String> args) {
  exitCode = run(args);
}
