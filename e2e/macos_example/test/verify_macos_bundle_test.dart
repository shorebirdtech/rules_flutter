/// Verifies the macOS .app bundle produced by flutter_macos_app has the
/// expected structure, including the native dylib and App.framework,
/// and is correctly wired for rendering (Info.plist, symbols, linkage, assets).
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  // flutter_macos_app sets bundle_name = app_name, so the .app is named
  // after the display name, not the Bazel target name.
  final bundle = MacosBundle.fromRunfiles('app.zip', appName: 'Flutter App');
  try {
    final check = bundle.check;
    bundle.checkFlutterLayout();

    check
      ..exists(
        'Native dylib libadd.dylib exists',
        '${bundle.frameworks}/libadd.dylib',
      )
      // Built at vendor/lib/libsub.dylib in its package. Loaded by file name,
      // so it has to be flattened into Frameworks/ like every other native
      // library.
      ..exists(
        'Native dylib from a package subdirectory is at Frameworks/libsub.dylib',
        '${bundle.frameworks}/libsub.dylib',
      )
      ..command(
        'Frameworks/libsub.dylib is a Mach-O dynamic library',
        'file',
        ['${bundle.frameworks}/libsub.dylib'],
        (stdout) => stdout.contains('Mach-O') && stdout.contains('dynamically'),
      );

    // A directory in Frameworks/ that is not a framework is a native library
    // bundled at its package-relative path. dyld never searches it, and
    // codesign rejects it as a bundle it cannot recognise.
    final frameworksDir = Directory(bundle.frameworks);
    final strayDirectories = [
      if (frameworksDir.existsSync())
        for (final entity in frameworksDir.listSync(followLinks: false))
          if (entity is Directory && !entity.path.endsWith('.framework'))
            entity.path.split('/').last,
    ];
    if (!frameworksDir.existsSync()) {
      check.fail('no Frameworks/ directory at ${frameworksDir.path}');
    } else {
      check.expect(
        'Frameworks/ holds no directory other than frameworks',
        condition: strayDirectories.isEmpty,
        detail:
            'Frameworks/ holds non-framework directories: '
            '${strayDirectories.join(', ')}',
      );
    }

    bundle
      ..checkInfoPlistValue('NSMainNibFile', 'MainMenu')
      ..checkInfoPlistValue('CFBundleExecutable', 'Flutter App')
      ..checkInfoPlistValue('CFBundleName', 'Flutter App')
      // From the app's `build_name` and `build_number`.
      ..checkInfoPlistValue('CFBundleShortVersionString', '2.3.4')
      ..checkInfoPlistValue('CFBundleVersion', '42');

    check.command('MainMenu.nib references AppDelegate class', 'strings', [
      '${bundle.contents}/Resources/Base.lproj/MainMenu.nib',
    ], (stdout) => stdout.contains('AppDelegate'));

    // flutter-create Swift files don't use @objc annotations, so class symbols
    // are Swift-mangled: _OBJC_CLASS_$__TtC6Runner11AppDelegate.
    bundle.checkRunnerClasses(['AppDelegate', 'MainFlutterWindow']);

    check.exists(
      'shaders/ directory exists',
      '${bundle.flutterAssets}/shaders',
    );

    bundle.finish('All macOS bundle verification checks passed.');
  } finally {
    bundle.dispose();
  }
}
