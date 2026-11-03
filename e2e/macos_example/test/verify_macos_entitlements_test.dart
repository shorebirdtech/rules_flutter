/// Verifies the entitlements blob codesign actually embedded in the bundle
/// `flutter_macos_app` produced — not the entitlements source files.
///
/// This is the regression test for the defect where a networked macOS app
/// works in `-c dbg` and is silently offline in release. `flutter create`
/// writes `com.apple.security.network.server` into
/// `macos/Runner/DebugProfile.entitlements` only, and `Release.entitlements`
/// declares nothing but `com.apple.security.app-sandbox`. The macro selects
/// between the pair by compilation mode, so the release bundle is sandboxed
/// with neither `network.server` nor `network.client` — the sandbox denies
/// the socket with no build error and no runtime exception.
///
/// `:app` therefore declares what it needs through
/// `flutter_macos_app(additional_entitlements = [...])`, which merges into
/// whichever base the mode selected. Bazel's default `fastbuild` is *not*
/// `-c dbg`, so the bundle this test reads carries the **release**
/// entitlements: finding the network keys in it proves the additions
/// survived into the release arm.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

/// Entitlements the signed bundle must carry in every compilation mode:
/// the sandbox the scaffold always declares, plus the two network
/// capabilities the app added for itself.
const _requiredEntitlements = <String>[
  'com.apple.security.app-sandbox',
  'com.apple.security.network.client',
  'com.apple.security.network.server',
];

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app.zip',
    appName: 'Flutter App',
    prefix: 'macos_entitlements_',
  );
  try {
    final check = bundle.check..exists('.app bundle', bundle.path);
    if (check.ok) {
      final entitlements = Entitlements.fromSignature(bundle.path);
      stdout
        ..writeln('--- codesign --entitlements ---')
        ..writeln(entitlements.blob)
        ..writeln('--- end ---');

      for (final entitlement in _requiredEntitlements) {
        check.expect(
          entitlement,
          condition: entitlements.declares(entitlement),
          detail: 'the signed bundle does not declare $entitlement',
        );
      }
    }

    if (!check.ok) {
      stderr.writeln(
        '\nA sandboxed release bundle that has lost a network '
        'entitlement its debug build had is invisible — no build error, no '
        'runtime exception, just an app with no peers. Declare the '
        'capability via flutter_macos_app(additional_entitlements = [...]), '
        'which applies in every compilation mode.',
      );
    }
    bundle.finish('\nAll macOS entitlement checks passed.');
  } finally {
    bundle.dispose();
  }
}
