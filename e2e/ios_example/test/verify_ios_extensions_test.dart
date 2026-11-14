/// Verifies the extensions `flutter_ios_app(extensions = [...])` embeds: each
/// `.appex` sits in the app's `PlugIns/`, declares the extension point it is
/// for, and the app and every extension carry the same App Group. The widget
/// extension also carries the App Intents metadata its control runs.
///
/// A simulator build is ad-hoc signed, so the entitlements are not in the
/// code signature. rules_apple links them into each binary's
/// `__TEXT,__entitlements` section instead, which is where the simulator reads
/// them, and where this test reads them too.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/app_extensions.dart';
import 'package:rules_flutter_e2e_testing/app_intents.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/plist.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

const _appGroup = 'group.com.rulesflutter.ios.example';

/// Each extension bundle and the extension point its Info.plist must name.
const _extensions = <String, String>{
  'share.appex': 'com.apple.share-services',
  'widgets.appex': 'com.apple.widgetkit-extension',
};

void main() {
  final bundle = IosBundle.fromRunfiles(
    'app_extensions.ipa',
    appName: 'app_extensions',
    prefix: 'ios_extensions_test',
  );
  try {
    final check = bundle.check;
    final extensions = EmbeddedExtensions(bundle.plugIns, _extensions)
      ..checkEmbedded(check)
      ..checkExtensionPoints(check, infoPlist: (appex) => '$appex/Info.plist');

    for (final appex in _extensions.keys) {
      final path = extensions.bundle(appex);
      final executable = Plist.read('$path/Info.plist')['CFBundleExecutable'];
      _checkGroup(check, '$path/$executable');
    }
    AppIntentsMetadata(extensions.bundle('widgets.appex'))
        .checkNames(check, 'PingIntent', owner: 'widgets.appex');

    final appExecutable = Plist.read(bundle.infoPlist)['CFBundleExecutable'];
    _checkGroup(check, '${bundle.path}/$appExecutable');

    bundle.finish('\nAll iOS extension checks passed.');
  } finally {
    bundle.dispose();
  }
}

/// Passes if [binary]'s embedded entitlements name the App Group.
void _checkGroup(BundleCheck check, String binary) {
  final name = binary.split('/').last;
  try {
    Entitlements.fromBinarySection(binary).checkInGroup(check, name, _appGroup);
  } on ProcessException catch (e) {
    check.fail('no entitlements section in $binary: ${e.message}');
  }
}
