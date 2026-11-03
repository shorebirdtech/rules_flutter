/// Checks on a built macOS `.app`, in the zip `flutter_macos_app` produces.
library;

import 'dart:io';

import 'archive.dart';
import 'bundle_check.dart';

/// A macOS app bundle unpacked from its zip.
class MacosBundle {
  MacosBundle._(this._archive, this.path, this.executable, this.check);

  /// Unpacks the zip at [zip] (a workspace path) and finds the app in it:
  /// `<appName>.app`, whose runner binary is [executable] (default [appName]).
  /// Call [dispose] when done.
  factory MacosBundle.fromRunfiles(
    String zip, {
    required String appName,
    String? executable,
    String prefix = 'macos_bundle_test',
  }) {
    final archive = ExtractedArchive.fromRunfiles(zip, prefix: prefix);
    return MacosBundle._(
      archive,
      '${archive.path}/$appName.app',
      executable ?? appName,
      BundleCheck(),
    );
  }

  final ExtractedArchive _archive;

  /// The `.app` directory.
  final String path;

  /// The file name of the runner binary in `Contents/MacOS`.
  final String executable;

  /// Where checks are recorded.
  final BundleCheck check;

  /// `Contents/`.
  String get contents => '$path/Contents';

  /// `Contents/Frameworks/`.
  String get frameworks => '$contents/Frameworks';

  /// The runner binary.
  String get runner => '$contents/MacOS/$executable';

  /// `Contents/Info.plist`.
  String get infoPlist => '$contents/Info.plist';

  /// `flutter_assets` inside `App.framework`.
  String get flutterAssets =>
      '$frameworks/App.framework/Resources/flutter_assets';

  /// Deletes the unpacked files.
  void dispose() => _archive.dispose();

  /// Checks what every Flutter macOS app holds: both frameworks, the runner, its
  /// `Info.plist`, a valid `App.framework/App`, and the asset manifests.
  ///
  /// [nib] is where the main menu nib sits under `Contents/Resources`, or null
  /// to skip the check on it and on `NSMainNibFile`.
  void checkFlutterLayout({String? nib = 'Base.lproj/MainMenu.nib'}) {
    check
      ..exists('App.framework exists', '$frameworks/App.framework')
      ..exists(
        'FlutterMacOS.framework exists',
        '$frameworks/FlutterMacOS.framework',
      )
      ..exists('Runner binary exists', runner)
      ..exists('Info.plist exists', infoPlist);
    if (nib != null) {
      check.exists('MainMenu.nib exists', '$contents/Resources/$nib');
    }
    check.exists('flutter_assets in App.framework', flutterAssets);
    check.command(
      'Runner binary links FlutterMacOS.framework',
      'otool',
      ['-L', runner],
      (stdout) => stdout.contains('FlutterMacOS.framework'),
    );
    final appBinary = '$frameworks/App.framework/App';
    check
      ..exists('App.framework/App binary exists', appBinary)
      ..command(
        'App.framework/App is valid Mach-O',
        'file',
        [appBinary],
        (stdout) => stdout.contains('Mach-O'),
      )
      ..exists('AssetManifest.bin exists', '$flutterAssets/AssetManifest.bin')
      ..exists('FontManifest.json exists', '$flutterAssets/FontManifest.json');
  }

  /// Checks that `Info.plist` has [key] set to [expected].
  void checkInfoPlistValue(String key, String expected) {
    check.command(
      'Info.plist $key is $expected',
      'plutil',
      ['-extract', key, 'raw', infoPlist],
      (stdout) => stdout == expected,
    );
  }

  /// Checks that the runner binary exports each of [classes] as an Objective-C
  /// class. Swift classes are name-mangled, so this matches by substring.
  void checkRunnerClasses(List<String> classes) {
    final result = Process.runSync('nm', ['-gU', runner]);
    if (result.exitCode != 0) {
      check.fail('nm -gU $runner failed: ${result.stderr}');
      return;
    }
    final symbols = result.stdout.toString();
    for (final name in classes) {
      check.expect(
        'Runner binary exports $name ObjC class',
        condition: symbols.contains(name),
        detail: 'Runner binary missing ObjC class $name',
      );
    }
  }

  /// Ends the test: prints [success] if every check passed; otherwise lists
  /// the bundle (without descending into frameworks) and exits 1.
  void finish(String success) {
    check.finish(
      success,
      onFailure: () {
        stderr.writeln('Bundle contents:');
        check.listTree(
          Directory(path),
          descend: (dir) => !dir.path.endsWith('.framework'),
        );
        dispose();
      },
    );
  }
}
