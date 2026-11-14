/// Verifies the extensions `flutter_macos_app(extensions = [...])` embeds:
/// each `.appex` sits in `Contents/PlugIns/`, declares the extension point it
/// is for, is sandboxed, and shares the app's App Group; the widget extension
/// carries the App Intents metadata its control runs; and the signature over
/// the whole bundle is valid.
///
/// macOS loads a widget or share extension only if it is sandboxed, and an
/// extension the app's signature does not seal is one codesign rejects and
/// the system will not load.
library;

import 'package:rules_flutter_e2e_testing/app_extensions.dart';
import 'package:rules_flutter_e2e_testing/app_intents.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

const _appGroup = 'group.com.example.flutterapp';

/// Each extension bundle and the extension point its Info.plist must name.
const _extensions = <String, String>{
  'share.appex': 'com.apple.share-services',
  'widgets.appex': 'com.apple.widgetkit-extension',
};

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app_extensions.zip',
    appName: 'Extensions App',
    prefix: 'macos_extensions_',
    preserveSignature: true,
  );
  try {
    final check = bundle.check;
    CodeSignature(bundle.path).checkValid(check);

    final extensions =
        EmbeddedExtensions('${bundle.contents}/PlugIns', _extensions)
          ..checkEmbedded(check)
          ..checkExtensionPoints(
            check,
            infoPlist: (appex) => '$appex/Contents/Info.plist',
          );
    for (final appex in _extensions.keys) {
      final entitlements = Entitlements.fromSignature(extensions.bundle(appex));
      check.expect(
        '$appex is sandboxed',
        condition: entitlements.isEnabled('com.apple.security.app-sandbox'),
        detail: '$appex is not sandboxed, so macOS will not load it',
      );
      entitlements.checkInGroup(check, appex, _appGroup);
    }
    Entitlements.fromSignature(bundle.path)
        .checkInGroup(check, 'Extensions App.app', _appGroup);

    AppIntentsMetadata(
      '${extensions.bundle('widgets.appex')}/Contents/Resources',
    ).checkNames(check, 'PingIntent', owner: 'widgets.appex');

    bundle.finish('\nAll macOS extension checks passed.');
  } finally {
    bundle.dispose();
  }
}
