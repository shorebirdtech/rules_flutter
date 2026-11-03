/// Checks on a built Linux or Windows bundle directory.
library;

import 'dart:io';

import 'bundle_check.dart';
import 'runfiles_paths.dart';

/// A bundle directory `flutter_linux_app` or `flutter_windows_app` produced,
/// found in the test's runfiles.
///
/// A bundle holds its runner next to the engine and a `data/` directory. The
/// two platforms name those differently; [LinuxBundle] and [WindowsBundle]
/// say how, and both check the layout every Flutter app has.
abstract class DesktopBundle {
  DesktopBundle(this.path, {BundleCheck? check})
    : name = path.split(RegExp(r'[\\/]')).last,
      check = check ?? BundleCheck();

  /// The bundle directory.
  final String path;

  /// The runner's name, which is also the bundle directory's.
  final String name;

  /// Where checks are recorded.
  final BundleCheck check;

  /// The runner binary.
  String get runner;

  /// Where `data/` is under [path].
  String get dataDir => '$path/data';

  /// `data/flutter_assets`.
  String get flutterAssets => '$dataDir/flutter_assets';

  /// The engine library the runner loads.
  String get engineLibrary;

  /// The AOT snapshot a release build holds.
  String get aotSnapshot;

  /// What the platform calls its bundle in the success line.
  String get platform;

  /// Checks the layout every Flutter app on this platform has: the runner,
  /// the engine, the Dart code (an AOT snapshot or, in a debug build, a kernel
  /// blob), the asset manifests and ICU data.
  void checkStandardLayout() {
    check
      ..exists('Runner binary', runner, nonEmpty: true)
      ..exists(
        engineLibrary.split(RegExp(r'[\\/]')).last,
        engineLibrary,
        nonEmpty: true,
      );
    final kernelBlob = '$flutterAssets/kernel_blob.bin';
    if (File(aotSnapshot).existsSync()) {
      check.exists('AOT snapshot', aotSnapshot, nonEmpty: true);
    } else if (File(kernelBlob).existsSync()) {
      check.exists('Kernel blob (debug)', kernelBlob, nonEmpty: true);
    } else {
      check.fail(
        'Neither ${_relative(aotSnapshot)} nor ${_relative(kernelBlob)} found',
      );
    }
    check
      ..exists('flutter_assets directory', flutterAssets)
      ..exists('AssetManifest.bin', '$flutterAssets/AssetManifest.bin')
      ..exists('FontManifest.json', '$flutterAssets/FontManifest.json')
      ..exists('NOTICES.Z', '$flutterAssets/NOTICES.Z')
      ..exists('icudtl.dat', '$dataDir/icudtl.dat', nonEmpty: true);
  }

  /// [relative], a path under the bundle, as a full path.
  String file(String relative) => '$path/$relative';

  /// Ends the test: prints the success line if every check passed; otherwise
  /// lists the bundle and exits 1.
  void finish() {
    check.finish(
      'All $platform bundle verification checks passed.',
      onFailure: () {
        stderr
          ..writeln()
          ..writeln('Actual bundle contents:');
        check.listTree(Directory(path));
      },
    );
  }

  String _relative(String file) => file.substring(path.length + 1);
}

/// A bundle from `flutter_linux_app`.
class LinuxBundle extends DesktopBundle {
  /// The bundle in directory [path].
  LinuxBundle(super.path, {super.check});

  /// The bundle that `workspacePath` (a target name or a path) names in the
  /// test's runfiles. Exits 1 if it is not there.
  LinuxBundle.fromRunfiles(String workspacePath)
    : super(requireRunfile(workspacePath, what: 'Bundle directory'));

  @override
  String get platform => 'Linux';

  @override
  String get runner => '$path/$name';

  @override
  String get engineLibrary => '$path/lib/libflutter_linux_gtk.so';

  @override
  String get aotSnapshot => '$path/lib/libapp.so';

  /// A shared library under `lib/`.
  String lib(String file) => '$path/lib/$file';
}

/// A bundle from `flutter_windows_app`.
class WindowsBundle extends DesktopBundle {
  /// The bundle in directory [path].
  WindowsBundle(super.path, {super.check});

  /// The bundle that `workspacePath` (a target name or a path) names in the
  /// test's runfiles. Exits 1 if it is not there.
  WindowsBundle.fromRunfiles(String workspacePath)
    : super(requireRunfile(workspacePath, what: 'Bundle directory'));

  @override
  String get platform => 'Windows';

  @override
  String get runner => '$path/$name.exe';

  @override
  String get engineLibrary => '$path/flutter_windows.dll';

  @override
  String get aotSnapshot => '$dataDir/app.so';
}
