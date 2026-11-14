/// Verifies the version.json each bundle ships, which the web
/// `package_info_plus` reads for the app's version:
///   - app_wasm:         no `build_name` or `build_number`, so `flutter
///                       create`'s 1.0.0 and 1.
///   - app_wasm_subpath: `build_name = "2.3.4"`, `build_number = "42"`.
library;

import 'dart:convert';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

void main() {
  final check = BundleCheck();

  void checkVersion({
    required String label,
    required String workspacePath,
    required String version,
    required String buildNumber,
  }) {
    final contents = WebBundle.fromRunfiles(
      workspacePath,
      check,
      label: label,
    ).read('version.json');
    if (contents == null) return;
    final json = jsonDecode(contents) as Map<String, Object?>;
    check
      ..expect(
        '$label: version.json version is $version',
        condition: json['version'] == version,
        detail: 'version.json: $contents',
      )
      ..expect(
        '$label: version.json build_number is $buildNumber',
        condition: json['build_number'] == buildNumber,
        detail: 'version.json: $contents',
      );
  }

  checkVersion(
    label: 'app_wasm',
    workspacePath: 'app_wasm_web',
    version: '1.0.0',
    buildNumber: '1',
  );
  checkVersion(
    label: 'app_wasm_subpath',
    workspacePath: 'app_wasm_subpath_web',
    version: '2.3.4',
    buildNumber: '42',
  );

  check.finish('All web version.json checks passed.');
}
