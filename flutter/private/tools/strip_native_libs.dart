/// Splits a jar into its classes and its stripped native libraries.
///
/// The Flutter engine ships as `flutter.jar`: the embedding's classes plus
/// `lib/<abi>/libflutter.so` (and, in the arm64 debug engine, the Vulkan
/// validation layer), all with full debug info. A Gradle build never packages
/// those as they are: the Android Gradle Plugin's `strip<Variant>DebugSymbols`
/// task runs the NDK's `llvm-strip --strip-unneeded` over every merged native
/// library, in every build type. This tool does the same for the jar
/// `flutter_android_engine` imports, so the APK carries what a Gradle-built
/// one does. `--strip-unneeded` keeps the dynamic symbol table, which is all
/// the loader and `dlsym` read.
///
/// The libraries leave the jar, into a zip of their own that keeps their
/// `lib/<abi>/` paths. `android_binary` builds one APK for every ABI its
/// platforms name, and takes the classes and resources of all of them from the
/// first alone, so a `lib/` entry inside a jar reaches the APK of the first
/// ABI only. A zip of libraries handed over as `AndroidNativeLibsInfo`, as an
/// AAR's are, reaches the APK of the ABI it was built for.
///
/// The tool has no package dependencies and runs with the bare Dart SDK. It
/// unpacks the jar with `zipper`, strips each `lib/**.so` entry in place, packs
/// those into `--libs` and every other entry into `--output`. A jar with no
/// native library is an error: the engine always has one, so finding none
/// means the input is not what the caller thinks it is.
///
/// Usage:
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       --input <jar> --output <jar> --libs <zip>
import 'dart:io';

/// The entries of [entries] that are native libraries: shared objects under
/// the jar's `lib/` directory, where `android_binary` takes them from.
List<String> nativeLibraries(Iterable<String> entries) => [
  for (final entry in entries)
    if (entry.startsWith('lib/') && entry.endsWith('.so')) entry,
];

/// The jar entry name of the file at [relativePath] in the unpacked jar,
/// whose path segments are joined by [separator]. Entry names always use
/// `/`; on Windows the unpacked paths use `\`.
String jarEntryName(String relativePath, String separator) =>
    relativePath.replaceAll(separator, '/');

/// The arguments the Android Gradle Plugin passes its strip tool.
List<String> stripArguments({required String input, required String output}) =>
    ['--strip-unneeded', '-o', output, input];

Map<String, String> _parseArgs(List<String> args) {
  const names = {'--zipper', '--strip', '--input', '--output', '--libs'};
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i];
    if (!names.contains(name) || i + 1 >= args.length) {
      throw ArgumentError('unexpected argument: $name');
    }
    values[name] = args[++i];
  }
  final missing = names.difference(values.keys.toSet());
  if (missing.isNotEmpty) {
    throw ArgumentError('missing ${missing.join(', ')}');
  }
  return values;
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final zipper = File(options['--zipper']!).absolute.path;
  final strip = File(options['--strip']!).absolute.path;
  final input = File(options['--input']!).absolute.path;
  final output = File(options['--output']!).absolute.path;
  final libsZip = File(options['--libs']!).absolute.path;

  final scratch = Directory.systemTemp.createTempSync('strip_native_libs');
  try {
    final unpacked = Directory('${scratch.path}/jar')..createSync();
    // zipper takes `-d` relative to its working directory, absolute or not.
    await _run(zipper, ['x', input], workingDirectory: unpacked.path);

    final entries = [
      for (final file in unpacked.listSync(recursive: true).whereType<File>())
        jarEntryName(
          file.path.substring(unpacked.path.length + 1),
          Platform.pathSeparator,
        ),
    ]..sort();

    final libraries = nativeLibraries(entries);
    if (libraries.isEmpty) {
      throw StateError('$input has no lib/**.so entry to strip');
    }
    for (final library in libraries) {
      final unstripped = '${unpacked.path}/$library';
      final stripped = '${scratch.path}/stripped.so';
      await _run(strip, stripArguments(input: unstripped, output: stripped));
      File(stripped).renameSync(unstripped);
    }

    // Compressed, as an AAR's libraries are.
    await _pack(zipper, libsZip, scratch.path, unpacked.path, libraries);
    await _pack(
      zipper,
      output,
      scratch.path,
      unpacked.path,
      entries.where((e) => !libraries.contains(e)).toList(),
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Packs [entries] of [root] into [zip], compressed.
Future<void> _pack(
  String zipper,
  String zip,
  String scratch,
  String root,
  List<String> entries,
) async {
  final argfile = File('$scratch/entries_${zip.hashCode}')
    ..writeAsStringSync(entries.map((e) => '$e=$root/$e\n').join());
  await _run(zipper, ['cC', zip, '@${argfile.path}']);
}
