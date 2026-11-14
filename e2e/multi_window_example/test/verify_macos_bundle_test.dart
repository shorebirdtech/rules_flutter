/// Verifies the macOS .app bundle produced by the multi-window example has the
/// expected structure: two-window runner with FlutterEngineGroup,
/// App.framework, FlutterMacOS.framework, and correct ObjC class symbols.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app_macos.zip',
    appName: 'Planner',
    prefix: 'multi_window_bundle_test',
  );
  try {
    bundle
      ..checkFlutterLayout(nib: 'MainMenu.nib')
      ..checkInfoPlistValue('NSMainNibFile', 'MainMenu')
      ..checkInfoPlistValue('CFBundleName', 'Planner')
      ..checkRunnerClasses(['AppDelegate', 'TasksWindow', 'CalendarWindow'])
      ..check.exists(
        'shaders/ directory exists',
        '${bundle.flutterAssets}/shaders',
      )
      ..finish('All multi-window macOS bundle verification checks passed.');
  } finally {
    bundle.dispose();
  }
}
