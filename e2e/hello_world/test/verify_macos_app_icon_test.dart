/// Verifies that the macOS bundle produced by `:hello_world_macos` ships the
/// app icon `flutter create` left in the tree.
///
/// Nothing in this workspace's BUILD file asks for one:
/// `flutter create --platforms=macos .` writes
/// `macos/Runner/Assets.xcassets/AppIcon.appiconset`, and `flutter_macos_app`
/// discovers it the same way it discovers the entitlements pair and the
/// Info.plist — so an app that has never thought about its icon ships the one
/// it already has, as `flutter build macos` does from the same tree.
///
/// Forwarding the catalog alone is not enough: `flutter create`'s
/// `Info.plist` declares `CFBundleIconFile` as an empty string for Xcode to
/// fill in, `macos_application` generates its own value from the catalog, and
/// Apple's plisttool refuses two different values for one key. The macro drops
/// the empty placeholder, which is why the value asserted below exists at all.
library;

import 'dart:convert';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/plist.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'hello_world_macos.zip',
    appName: 'Hello World',
    prefix: 'hello_world_macos_icon_',
  );
  try {
    final check = bundle.check;
    final resources = '${bundle.contents}/Resources';

    // actool's two outputs. The `.icns` is what the Finder and the Dock read;
    // `Assets.car` is the compiled catalog the app reads at runtime. A build
    // that forwarded the catalog but never told actool which set was the app
    // icon would produce the second and not the first.
    for (final name in const ['AppIcon.icns', 'Assets.car']) {
      check.exists(name, '$resources/$name', nonEmpty: true);
    }

    // The key the scaffold left empty, carrying actool's value.
    final iconFile = Plist.read(bundle.infoPlist)['CFBundleIconFile'];
    check.expect(
      'CFBundleIconFile = $iconFile',
      condition: iconFile == 'AppIcon',
      detail:
          'CFBundleIconFile is ${jsonEncode(iconFile)}, expected "AppIcon". '
          'An empty string means the scaffold placeholder survived and actool '
          'never named the icon.',
    );

    bundle.finish('PASS: the macOS bundle ships the app icon from the tree');
  } finally {
    bundle.dispose();
  }
}
