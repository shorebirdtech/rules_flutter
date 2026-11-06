/// Checks on a built Android APK.
library;

import 'dart:io';

import 'apk_contents.dart';
import 'archive.dart';
import 'bundle_check.dart';
import 'elf.dart';
import 'runfiles_paths.dart';
import 'zip_entries.dart';

/// An APK extracted to a temporary directory, with the checks every Android
/// test makes of one.
class Apk {
  /// Wraps the APK [apkFile] extracted to [archive], recording checks in
  /// [check].
  Apk(this.archive, {required this.apkFile, BundleCheck? check})
    : check = check ?? BundleCheck();

  /// Extracts the APK at [workspacePath] in the test's runfiles
  /// (`app.apk`, `glass_app/glass_android.apk`). [prefix] names the temporary
  /// directory.
  ///
  /// Unpacks with Bazel's zipper, so the test target needs the `data` and
  /// `env` that [zipperRunfileEnv] describes. Exits 1 if the APK is missing
  /// or does not unpack.
  factory Apk.fromRunfiles(
    String workspacePath, {
    String prefix = 'apk_test',
    BundleCheck? check,
  }) {
    final apkFile = requireRunfile(workspacePath, what: 'APK');
    return Apk(
      ExtractedArchive.fromPath(
        apkFile,
        prefix: prefix,
        extractor: Extractor.zipper,
      ),
      apkFile: apkFile,
      check: check,
    );
  }

  /// The APK itself.
  final String apkFile;

  /// The extracted files.
  final ExtractedArchive archive;

  /// Where checks are recorded.
  final BundleCheck check;

  /// The extraction directory.
  String get path => archive.path;

  /// The file at [relative] in the APK, which may not exist.
  File file(String relative) => File('$path/$relative');

  /// The compiled binary `AndroidManifest.xml`.
  File get manifest => file('AndroidManifest.xml');

  /// The names of the ABI directories under `lib/`, sorted.
  List<String> get abis => [
    if (_libDir.existsSync())
      for (final dir in _libDir.listSync().whereType<Directory>())
        _basename(dir.path),
  ]..sort();

  Directory get _libDir => Directory('$path/lib');

  /// Whether the file at [relative] exists and contains [text] as UTF-8 or
  /// UTF-16LE: see [containsText].
  bool fileHasText(String relative, String text) {
    final f = file(relative);
    return f.existsSync() && containsText(f.readAsBytesSync(), text);
  }

  /// The descriptors of every class the APK's `classes*.dex` files define.
  Set<String> definedClasses() => {
    for (final dex in Directory(path).listSync().whereType<File>())
      if (RegExp(r'classes\d*\.dex$').hasMatch(dex.path))
        ...definedClassDescriptors(dex),
  };

  /// The compile-time constants of every class the APK's dex files define,
  /// by class descriptor and field name: see [dexStaticConstants].
  Map<String, Map<String, Object?>> staticConstants() => {
    for (final dex in Directory(path).listSync().whereType<File>())
      if (RegExp(r'classes\d*\.dex$').hasMatch(dex.path))
        ...dexStaticConstants(dex.readAsBytesSync()),
  };

  /// Checks that every native library under `lib/<abi>/` is an ELF shared
  /// object for its ABI directory's machine, and that there is at least one.
  ///
  /// Android's linker cannot load anything else (a host-format Mach-O
  /// `libapp.so` crashes at startup with "VM snapshot invalid"). A library
  /// whose `PT_LOAD` segments are aligned below [minLoadAlignment] also
  /// fails; the default, 16384, is what a 16KB-page device requires.
  void checkNativeLibraries({int minLoadAlignment = 16384}) {
    var checked = 0;
    if (_libDir.existsSync()) {
      for (final abiDir in _libDir.listSync().whereType<Directory>()) {
        final abi = _basename(abiDir.path);
        final machine = elfMachineForAbi[abi];
        if (machine == null) {
          check.fail('unexpected ABI directory lib/$abi');
          continue;
        }
        for (final lib in abiDir.listSync().whereType<File>()) {
          checked++;
          _checkLibrary(lib, abi, machine, minLoadAlignment);
        }
      }
    }
    if (checked == 0) check.fail('no native libraries found under lib/');
  }

  void _checkLibrary(File lib, String abi, int machine, int minAlign) {
    final name = 'lib/$abi/${_basename(lib.path)}';
    final elf = ElfImage.fromFile(lib);
    final error = elf.validate(machine);
    if (error != null) {
      check.fail('$name — $error');
      return;
    }
    final (align, alignError) = elf.minLoadAlignment();
    if (alignError != null) {
      check.fail('$name — $alignError');
    } else if (align! < minAlign) {
      check.fail(
        '$name has LOAD alignment 0x${align.toRadixString(16)}, below the '
        '$minAlign a 16KB-page device requires. It would install and then '
        'fail to load at launch ("ELF alignment check failed") on hardware '
        'booted that way, with nothing wrong at build time. See the '
        'rules_android_ndk pin in MODULE.bazel.',
      );
    } else {
      check.pass(
        '$name is ELF (machine 0x${machine.toRadixString(16)}, '
        'correct for $abi) aligned 0x${align.toRadixString(16)}',
      );
    }
  }

  /// Checks that the native libraries are packaged as AGP packages them for
  /// a minimum SDK of 23 or more (`jniLibs.useLegacyPackaging = false`, its
  /// default): every `lib/<abi>/*.so` stored uncompressed at a
  /// [pageSize]-aligned offset, so Android maps it straight from the APK, and
  /// the manifest's `<application android:extractNativeLibs="false">`, so the
  /// installer does not copy it out as well.
  void checkNativeLibrariesUncompressed({int pageSize = 16384}) {
    var checked = 0;
    for (final entry in zipEntries(File(apkFile).readAsBytesSync())) {
      if (!RegExp(r'^lib/[^/]+/[^/]+\.so$').hasMatch(entry.name)) continue;
      checked++;
      if (!entry.stored) {
        check.fail('${entry.name} is compressed (method ${entry.method})');
      } else if (entry.dataOffset % pageSize != 0) {
        check.fail(
          '${entry.name} is stored at offset ${entry.dataOffset}, which is '
          'not $pageSize-aligned',
        );
      } else {
        check.pass('${entry.name} is stored $pageSize-aligned');
      }
    }
    if (checked == 0) check.fail('no native libraries found under lib/');
    final extract = [
      for (final e in manifestElements(manifest.readAsBytesSync()))
        if (e.name == 'application') e.attributes['extractNativeLibs'],
    ];
    check.expect(
      'the manifest says android:extractNativeLibs="false"',
      condition: extract.length == 1 && extract.single == 'false',
      detail: 'android:extractNativeLibs $extract',
    );
  }

  /// Checks that no Kotlin Multiplatform metadata is packaged: the
  /// `<sourceSet>/default/linkdata/...` klib files that make up the
  /// common artifact of a multiplatform library (`androidx.collection`,
  /// `kotlinx-coroutines-core`). Gradle resolves such a library to its JVM or
  /// Android variant and never packages the common one.
  void checkNoMultiplatformMetadata() {
    final metadata = [
      for (final entry in zipEntries(File(apkFile).readAsBytesSync()))
        if (_klibMetadata.hasMatch(entry.name)) entry.name,
    ];
    check.expect(
      'no Kotlin Multiplatform metadata',
      condition: metadata.isEmpty,
      detail:
          '${metadata.length} entries, such as ${metadata.take(5).join(', ')}',
    );
  }

  /// Checks that the dex files define every class in [required], keyed by
  /// what ships it.
  void checkDefinedClasses(Map<String, String> required) {
    final defined = definedClasses();
    if (defined.isEmpty) {
      check.fail('no class definitions parsed from dex files');
    }
    required.forEach((source, descriptor) {
      if (defined.contains(descriptor)) {
        check.pass('$descriptor defined in dex ($source)');
      } else {
        check.fail(
          '$descriptor not defined in any dex — '
          '$source is missing from the APK',
        );
      }
    });
  }

  /// Ends a test of this one APK: prints [success] if every check passed,
  /// otherwise lists the APK's contents and exits 1. Removes the extraction
  /// either way.
  void finish(String success) {
    check.finish(
      success,
      onFailure: () {
        listContents();
        dispose();
      },
    );
    dispose();
  }

  /// Writes the APK's files to stderr, to read after a failed check.
  void listContents() {
    stderr.writeln('\nAPK contents:');
    check.listTree(archive.dir);
  }

  /// Removes the extraction.
  void dispose() => archive.dispose();
}

final _klibMetadata = RegExp('^[A-Za-z0-9]+Main/default/');

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
