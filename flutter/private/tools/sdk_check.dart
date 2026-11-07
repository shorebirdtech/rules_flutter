/// Checks that the pieces of a Flutter SDK were built from one Dart.
///
/// An engine's Dart VM only accepts kernel of its own format and, in the AOT
/// modes, snapshots whose 32-character snapshot hash equals its own. A stock
/// SDK satisfies this by construction; an engine built from a checkout does
/// not unless every piece came from that one checkout. This tool reads the
/// fingerprints out of the artifacts and fails, naming each artifact by label
/// and path with the values it found, when they disagree:
///
/// * Kernel (every mode): the engine's `platform_strong.dill` and the Dart
///   SDK's `vm_platform_strong.dill` have the same kernel format version and
///   the same SDK hash. The hash `0000000000` disables the VM's own SDK-hash
///   check, so it matches anything.
/// * Snapshot hash (profile and release): the candidate hashes found in
///   `gen_snapshot` and in the engine binary share exactly one value. In debug
///   there is no `gen_snapshot`, and the value is the one the engine binary
///   shares with `dartaotruntime`.
/// * Same Dart (every mode): `dartaotruntime` and the engine binary share
///   exactly one hash, which in the AOT modes is the `gen_snapshot` one.
///
/// A snapshot hash candidate is a run of exactly 32 lowercase hex characters
/// that is followed by a NUL byte and not preceded by another `[0-9a-z]` byte.
/// Taking a set of candidates from each file, rather than assuming one, keeps
/// an unrelated hex constant from breaking the check: an empty intersection is
/// a mismatch, more than one common value is a failure to determine the hash,
/// and both fail.
///
/// On success the tool writes `--record-out`: the JSON object of `--record-in`
/// plus `snapshot_hash` and `kernel` (`format`, `sdk_hash`), with sorted keys
/// so the bytes are stable. On a failed check it writes nothing, prints the
/// reason to stderr and exits 1.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
///
/// Usage (every flag as `--name=value`):
///   dart sdk_check.dart --mode=debug|profile|release
///       --engine-binary=<path> [--engine-binary-entry=<zip entry>]
///       --engine-label=<label>
///       [--gen-snapshot=<path> --gen-snapshot-label=<label>]
///       --engine-platform-dill=<path> --engine-platform-dill-label=<label>
///       --dart-platform-dill=<path> --dart-platform-dill-label=<label>
///       --dartaotruntime=<path> --dartaotruntime-label=<label>
///       [--framework=<flutter_framework.json>]
///       --record-in=<path> --record-out=<path>
///
/// `--gen-snapshot` is required for `profile` and `release` and must be absent
/// for `debug`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The SDK hash that switches the VM's SDK-hash check off.
const disabledSdkHash = '0000000000';

/// The bytes every kernel file starts with.
const _kernelMagic = [0x90, 0xab, 0xcd, 0xef];

/// Magic, 4-byte big-endian format version, 10-byte ASCII SDK hash.
const _kernelHeaderLength = 4 + 4 + 10;

/// The modes the tool knows, and the ones that have a `gen_snapshot`.
const _modes = ['debug', 'profile', 'release'];

/// One file of the SDK, named the way messages name it. With an [entry], the
/// file is that entry of the zip at [path]: an Android engine's
/// `libflutter.so` lives inside `flutter.jar`.
class Artifact {
  const Artifact(this.label, this.path, {this.entry});

  final String label;
  final String path;
  final String? entry;

  /// Where the file is, for a message.
  String get location => entry == null ? path : '$path, entry $entry';
}

/// A check that failed. [message] is the whole text for stderr.
class SdkCheckFailure implements Exception {
  SdkCheckFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The part of a kernel file's header the VM compares.
class KernelHeader {
  const KernelHeader(this.format, this.sdkHash);

  final int format;
  final String sdkHash;

  @override
  String toString() => 'kernel format $format, SDK hash $sdkHash';
}

/// Reads the header of the kernel file [artifact].
KernelHeader readKernelHeader(Artifact artifact) {
  final file = File(artifact.path);
  final RandomAccessFile handle = file.openSync();
  final Uint8List head;
  try {
    head = handle.readSync(_kernelHeaderLength);
  } finally {
    handle.closeSync();
  }
  if (head.length < _kernelHeaderLength) {
    throw SdkCheckFailure(
      'Not a kernel file: ${artifact.label}\n'
      '(${artifact.path})\n'
      'is ${head.length} bytes long and a kernel header takes '
      '$_kernelHeaderLength.',
    );
  }
  for (var i = 0; i < _kernelMagic.length; i++) {
    if (head[i] != _kernelMagic[i]) {
      throw SdkCheckFailure(
        'Not a kernel file: ${artifact.label}\n'
        '(${artifact.path})\n'
        'does not start with the kernel magic bytes 90 ab cd ef.',
      );
    }
  }
  final format = ByteData.sublistView(head).getUint32(4);
  final hashBytes = head.sublist(8, _kernelHeaderLength);
  if (hashBytes.any((b) => b < 0x20 || b > 0x7e)) {
    throw SdkCheckFailure(
      'Not a kernel file: ${artifact.label}\n'
      '(${artifact.path})\n'
      'has an SDK hash field that is not ASCII text.',
    );
  }
  return KernelHeader(format, String.fromCharCodes(hashBytes));
}

bool _isHexLower(int b) => (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66);

bool _isAlnumLower(int b) =>
    (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7a);

/// Collects snapshot hash candidates from a stream of chunks.
///
/// Tracks the current run of `[0-9a-z]` bytes across chunk boundaries, so a
/// candidate that straddles two chunks is found and nothing is held in memory
/// beyond one chunk.
class _HashScanner {
  final found = <String>{};
  final _run = Uint8List(32);

  // Length of the current run of [0-9a-z] bytes, saturating at 33.
  var _runLength = 0;
  var _runIsHex = true;

  void add(List<int> chunk, int length) {
    for (var i = 0; i < length; i++) {
      final b = chunk[i];
      if (_isAlnumLower(b)) {
        if (_runLength < 32) {
          _run[_runLength] = b;
          _runIsHex = _runIsHex && _isHexLower(b);
        }
        if (_runLength < 33) {
          _runLength++;
        }
      } else {
        if (b == 0 && _runLength == 32 && _runIsHex) {
          found.add(String.fromCharCodes(_run));
        }
        _runLength = 0;
        _runIsHex = true;
      }
    }
  }
}

/// Every snapshot hash candidate in the file at [path], read in chunks.
Set<String> snapshotHashCandidates(String path, {int chunkSize = 1 << 20}) {
  final scanner = _HashScanner();
  final handle = File(path).openSync();
  try {
    final chunk = Uint8List(chunkSize);
    while (true) {
      final read = handle.readIntoSync(chunk);
      if (read == 0) {
        break;
      }
      scanner.add(chunk, read);
    }
  } finally {
    handle.closeSync();
  }
  return scanner.found;
}

class _ChunkSink extends ByteConversionSinkBase {
  _ChunkSink(this._onChunk);

  final void Function(List<int> chunk) _onChunk;

  @override
  void add(List<int> chunk) => _onChunk(chunk);

  @override
  void close() {}
}

int _u16(Uint8List b, int o) => b[o] | b[o + 1] << 8;
int _u32(Uint8List b, int o) => _u16(b, o) | _u16(b, o + 2) << 16;

/// Every snapshot hash candidate in [entry] of the zip at [path].
///
/// Reads the entry's data straight from the archive (stored, or deflated and
/// inflated in chunks), since the tool has no archive library. Zip64 archives
/// are refused: an engine jar is far below 4 GB.
Set<String> zipEntryHashCandidates(
  Artifact artifact, {
  int chunkSize = 1 << 20,
}) {
  final path = artifact.path;
  final entry = artifact.entry!;
  SdkCheckFailure failure(String why) => SdkCheckFailure(
    'Cannot read $entry from ${artifact.label}\n($path)\n$why',
  );

  final handle = File(path).openSync();
  try {
    final length = handle.lengthSync();
    final tailLength = length < 65557 ? length : 65557;
    handle.setPositionSync(length - tailLength);
    final tail = handle.readSync(tailLength);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw failure('It is not a zip archive.');
    }
    final count = _u16(tail, eocd + 10);
    final directorySize = _u32(tail, eocd + 12);
    final directoryOffset = _u32(tail, eocd + 16);
    if (count == 0xffff || directorySize == 0xffffffff) {
      throw failure('Zip64 archives are not supported.');
    }
    handle.setPositionSync(directoryOffset);
    final directory = handle.readSync(directorySize);

    var at = 0;
    for (var n = 0; n < count; n++) {
      if (_u32(directory, at) != 0x02014b50) {
        throw failure('Its central directory is damaged.');
      }
      final method = _u16(directory, at + 10);
      final compressed = _u32(directory, at + 20);
      final nameLength = _u16(directory, at + 28);
      final extraLength = _u16(directory, at + 30);
      final commentLength = _u16(directory, at + 32);
      final localOffset = _u32(directory, at + 42);
      final name = utf8.decode(
        directory.sublist(at + 46, at + 46 + nameLength),
        allowMalformed: true,
      );
      at += 46 + nameLength + extraLength + commentLength;
      if (name != entry) {
        continue;
      }
      if (compressed == 0xffffffff || localOffset == 0xffffffff) {
        throw failure('Zip64 archives are not supported.');
      }
      handle.setPositionSync(localOffset);
      final local = handle.readSync(30);
      if (_u32(local, 0) != 0x04034b50) {
        throw failure('Its local header is damaged.');
      }
      final dataOffset = localOffset + 30 + _u16(local, 26) + _u16(local, 28);
      handle.setPositionSync(dataOffset);

      final scanner = _HashScanner();
      void feed(List<int> bytes) => scanner.add(bytes, bytes.length);
      final ByteConversionSink inflater;
      if (method == 0) {
        inflater = _ChunkSink(feed);
      } else if (method == 8) {
        inflater = ZLibDecoder(raw: true).startChunkedConversion(
          _ChunkSink(feed),
        );
      } else {
        throw failure('Its compression method $method is not supported.');
      }
      var remaining = compressed;
      while (remaining > 0) {
        final chunk = handle.readSync(
          remaining < chunkSize ? remaining : chunkSize,
        );
        if (chunk.isEmpty) {
          throw failure('The archive ends inside the entry.');
        }
        inflater.add(chunk);
        remaining -= chunk.length;
      }
      inflater.close();
      return scanner.found;
    }
    throw failure('The archive has no such entry.');
  } finally {
    handle.closeSync();
  }
}

/// Every snapshot hash candidate in [artifact].
Set<String> artifactHashCandidates(Artifact artifact) => artifact.entry == null
    ? snapshotHashCandidates(artifact.path)
    : zipEntryHashCandidates(artifact);

String _describeHashes(Set<String> hashes) {
  if (hashes.isEmpty) {
    return 'no snapshot hash found';
  }
  final sorted = hashes.toList()..sort();
  return sorted.length == 1
      ? 'snapshot hash ${sorted.single}'
      : 'snapshot hashes ${sorted.join(', ')}';
}

/// The lines naming one artifact: its role, label, path and [detail].
String _entry(String role, Artifact artifact, String detail) {
  const roleWidth = 15;
  final indent = ' ' * (2 + roleWidth);
  return '  ${role.padRight(roleWidth)}${artifact.label}\n'
      '$indent(${artifact.location})\n'
      '$indent$detail';
}

/// What the file at [artifact] holds, in the fields the checks read.
class _Scan {
  _Scan(this.artifact) : hashes = artifactHashCandidates(artifact);

  final Artifact artifact;
  final Set<String> hashes;

  String get detail => _describeHashes(hashes);
}

/// Checks the kernel headers of the two platform dills and returns the header
/// to record.
KernelHeader _checkKernel(String mode, Artifact engineDill, Artifact dartDill) {
  final engine = readKernelHeader(engineDill);
  final dart = readKernelHeader(dartDill);
  final differences = <String>[
    if (engine.format != dart.format)
      'kernel format ${engine.format} vs ${dart.format}',
    if (engine.sdkHash != dart.sdkHash &&
        engine.sdkHash != disabledSdkHash &&
        dart.sdkHash != disabledSdkHash)
      'SDK hash ${engine.sdkHash} vs ${dart.sdkHash}',
  ];
  if (differences.isNotEmpty) {
    throw SdkCheckFailure(
      'The Flutter SDK does not match itself for $mode:\n'
      '${_entry('engine', engineDill, engine.toString())}\n'
      '${_entry('Dart SDK', dartDill, dart.toString())}\n'
      'The engine\'s platform dill and the Dart SDK come from different Dart '
      'revisions (${differences.join('; ')}), so the engine would reject the '
      'kernel the Dart SDK compiles. Use the platform dill and the Dart SDK '
      'of one checkout.',
    );
  }
  final sdkHash = engine.sdkHash != disabledSdkHash
      ? engine.sdkHash
      : dart.sdkHash;
  return KernelHeader(engine.format, sdkHash);
}

/// The one value [a] and [b] share, or a [SdkCheckFailure] built by
/// [mismatch] (no value shared) or [ambiguous] (several).
String _theCommonHash(
  Set<String> a,
  Set<String> b, {
  required SdkCheckFailure Function() mismatch,
  required SdkCheckFailure Function(List<String> common) ambiguous,
}) {
  final common = a.intersection(b).toList()..sort();
  if (common.isEmpty) {
    throw mismatch();
  }
  if (common.length > 1) {
    throw ambiguous(common);
  }
  return common.single;
}

/// Runs every check and returns the record: [record] plus `snapshot_hash` and
/// `kernel`. Throws a [SdkCheckFailure] naming what disagrees.
Map<String, Object?> check({
  required String mode,
  required Artifact engineBinary,
  Artifact? genSnapshot,
  required Artifact enginePlatformDill,
  required Artifact dartPlatformDill,
  required Artifact dartaotruntime,
  required Map<String, Object?> record,
}) {
  if (!_modes.contains(mode)) {
    throw SdkCheckFailure(
      '--mode is "$mode"; it must be one of ${_modes.join(', ')}.',
    );
  }
  final aot = mode != 'debug';
  if (aot && genSnapshot == null) {
    throw SdkCheckFailure('A $mode check needs --gen-snapshot.');
  }
  if (!aot && genSnapshot != null) {
    throw SdkCheckFailure('A debug check has no gen_snapshot to take.');
  }

  final kernel = _checkKernel(mode, enginePlatformDill, dartPlatformDill);

  final engine = _Scan(engineBinary);
  final runtime = _Scan(dartaotruntime);
  final gen = genSnapshot == null ? null : _Scan(genSnapshot);

  // The hash to record: gen_snapshot's and the engine's common value, or in
  // debug the engine's and dartaotruntime's.
  final String snapshotHash;
  if (gen != null) {
    snapshotHash = _theCommonHash(
      gen.hashes,
      engine.hashes,
      mismatch: () => SdkCheckFailure(
        'The Flutter SDK does not match itself for $mode:\n'
        '${_entry('gen_snapshot', gen.artifact, gen.detail)}\n'
        '${_entry('engine', engine.artifact, engine.detail)}\n'
        'An engine only runs code compiled by a gen_snapshot from the same '
        'Dart. Rebuild both from one checkout.',
      ),
      ambiguous: (common) => SdkCheckFailure(
        'The snapshot hash of the Flutter SDK cannot be determined for '
        '$mode:\n'
        '${_entry('gen_snapshot', gen.artifact, gen.detail)}\n'
        '${_entry('engine', engine.artifact, engine.detail)}\n'
        'gen_snapshot and the engine share ${common.length} candidate '
        'hashes (${common.join(', ')}) and the check cannot tell which is '
        'the VM\'s.',
      ),
    );
  } else {
    snapshotHash = _theCommonHash(
      engine.hashes,
      runtime.hashes,
      mismatch: () => _runtimeMismatch(mode, engine, runtime),
      ambiguous: (common) => _runtimeAmbiguous(mode, engine, runtime, common),
    );
  }

  final runtimeHash = _theCommonHash(
    runtime.hashes,
    engine.hashes,
    mismatch: () => _runtimeMismatch(mode, engine, runtime),
    ambiguous: (common) => _runtimeAmbiguous(mode, engine, runtime, common),
  );
  if (runtimeHash != snapshotHash) {
    throw SdkCheckFailure(
      'The Dart SDK does not match the Flutter engine for $mode:\n'
      '${_entry('gen_snapshot', gen!.artifact, gen.detail)}\n'
      '${_entry('engine', engine.artifact, engine.detail)}\n'
      '${_entry('dartaotruntime', runtime.artifact, runtime.detail)}\n'
      'The engine and gen_snapshot agree on $snapshotHash but the Dart SDK '
      'is $runtimeHash. The Dart SDK that compiles the app must be the Dart '
      'the engine was built with. Use the Dart SDK of the engine\'s '
      'checkout.',
    );
  }

  return _sorted({
    ...record,
    'snapshot_hash': snapshotHash,
    'kernel': {'format': kernel.format, 'sdk_hash': kernel.sdkHash},
  });
}

SdkCheckFailure _runtimeMismatch(String mode, _Scan engine, _Scan runtime) =>
    SdkCheckFailure(
      'The Dart SDK does not match the Flutter engine for $mode:\n'
      '${_entry('engine', engine.artifact, engine.detail)}\n'
      '${_entry('dartaotruntime', runtime.artifact, runtime.detail)}\n'
      'The Dart SDK that compiles the app must be the Dart the engine was '
      'built with. Use the Dart SDK of the engine\'s checkout.',
    );

SdkCheckFailure _runtimeAmbiguous(
  String mode,
  _Scan engine,
  _Scan runtime,
  List<String> common,
) => SdkCheckFailure(
  'The snapshot hash of the Dart SDK cannot be determined for $mode:\n'
  '${_entry('engine', engine.artifact, engine.detail)}\n'
  '${_entry('dartaotruntime', runtime.artifact, runtime.detail)}\n'
  'dartaotruntime and the engine share ${common.length} candidate hashes '
  '(${common.join(', ')}) and the check cannot tell which is the VM\'s.',
);

/// [value] with every map's keys in sorted order, recursively.
Map<String, Object?> _sorted(Map<String, Object?> value) {
  final keys = value.keys.toList()..sort();
  return {
    for (final key in keys)
      key: switch (value[key]) {
        final Map<String, Object?> map => _sorted(map),
        final other => other,
      },
  };
}

/// The framework entry of the record: the `flutter_framework.json` at [path]
/// less what names the machine it was read on (a `path` key, and any value that
/// is an absolute path), since the record travels with the app.
Map<String, Object?> frameworkRecord(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw SdkCheckFailure('$path is not a JSON object.');
  }
  return {
    for (final entry in decoded.entries)
      if (entry.key != 'path' &&
          !(entry.value is String && (entry.value as String).startsWith('/')))
        entry.key: entry.value,
  };
}

/// The text written to `--record-out`.
String encodeRecord(Map<String, Object?> record) =>
    '${const JsonEncoder.withIndent('  ').convert(record)}\n';

const _flagNames = {
  'mode',
  'engine-binary',
  'engine-binary-entry',
  'engine-label',
  'gen-snapshot',
  'gen-snapshot-label',
  'engine-platform-dill',
  'engine-platform-dill-label',
  'dart-platform-dill',
  'dart-platform-dill-label',
  'dartaotruntime',
  'dartaotruntime-label',
  'framework',
  'record-in',
  'record-out',
};

Map<String, String> _parseFlags(List<String> args) {
  final flags = <String, String>{};
  for (final arg in args) {
    final match = RegExp(r'^--([a-z-]+)=(.*)$', dotAll: true).firstMatch(arg);
    if (match == null || !_flagNames.contains(match.group(1))) {
      throw SdkCheckFailure('Unknown argument: $arg');
    }
    flags[match.group(1)!] = match.group(2)!;
  }
  return flags;
}

/// Runs the tool over [args] (the command line), prints failures to [err] and
/// returns the exit code.
int run(List<String> args, {StringSink? err}) {
  final sink = err ?? stderr;
  try {
    final flags = _parseFlags(args);
    String need(String name) {
      final value = flags[name];
      if (value == null || value.isEmpty) {
        throw SdkCheckFailure('Missing --$name.');
      }
      return value;
    }

    Artifact artifact(String flag) => Artifact(need('$flag-label'), need(flag));

    final genSnapshot = flags.containsKey('gen-snapshot')
        ? artifact('gen-snapshot')
        : null;
    if (genSnapshot == null && flags.containsKey('gen-snapshot-label')) {
      throw SdkCheckFailure(
        '--gen-snapshot-label is given without --gen-snapshot.',
      );
    }

    final Object? recordIn = jsonDecode(
      File(need('record-in')).readAsStringSync(),
    );
    if (recordIn is! Map<String, Object?>) {
      throw SdkCheckFailure('${need('record-in')} is not a JSON object.');
    }

    final frameworkPath = flags['framework'];
    if (frameworkPath != null) {
      recordIn['framework'] = frameworkRecord(frameworkPath);
    }

    final record = check(
      mode: need('mode'),
      engineBinary: Artifact(
        need('engine-label'),
        need('engine-binary'),
        entry: flags['engine-binary-entry'],
      ),
      genSnapshot: genSnapshot,
      enginePlatformDill: artifact('engine-platform-dill'),
      dartPlatformDill: artifact('dart-platform-dill'),
      dartaotruntime: artifact('dartaotruntime'),
      record: recordIn,
    );
    File(need('record-out')).writeAsStringSync(encodeRecord(record));
    return 0;
  } on SdkCheckFailure catch (failure) {
    sink.writeln(failure.message);
    return 1;
  } on FileSystemException catch (error) {
    final cause = error.osError?.message ?? error.message;
    sink.writeln('Cannot read ${error.path ?? 'a file'}: $cause');
    return 1;
  }
}

void main(List<String> args) => exit(run(args));
