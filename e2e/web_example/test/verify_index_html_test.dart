/// Verifies bundled web index.html files have Flutter's $FLUTTER_BASE_HREF
/// placeholder substituted with the rule's `base_href` value, exercising
/// the three code paths:
///   - app_wasm:         Tier 1 (flutter_web_app) with user-provided
///                       web/index.html and the default base_href "/".
///   - app_wasm_subpath: Same Tier 1 path with a non-default base_href.
///   - app_js:           Tier 2 (flutter_web_bundle) with no index.html of its
///                       own, so the rule's built-in template is substituted.
///
/// Runs as a Bazel dart_test with all three bundles as data dependencies.
library;

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

void main() {
  final check = BundleCheck();

  void checkIndex({
    required String label,
    required String workspacePath,
    required String expectedBase,
  }) {
    final contents = WebBundle.fromRunfiles(
      workspacePath,
      check,
      label: label,
    ).read('index.html');
    if (contents == null) return;

    check
      ..expect(
        '$label: bundled index.html has no \$FLUTTER_BASE_HREF left',
        condition: !contents.contains(r'$FLUTTER_BASE_HREF'),
        detail: r'bundled index.html still contains $FLUTTER_BASE_HREF',
      )
      ..expect(
        '$label: `$expectedBase` substituted into index.html',
        condition: contents.contains(expectedBase),
        detail:
            'expected `$expectedBase` not found in bundled index.html\n'
            'Actual contents:\n$contents',
      );
  }

  // Tier 1 (flutter_web_app) with user-provided web/index.html and the
  // default base_href = "/".
  checkIndex(
    label: 'app_wasm (default base_href)',
    workspacePath: 'app_wasm_web',
    expectedBase: '<base href="/">',
  );

  // Same Tier 1 path with a non-default base_href.
  checkIndex(
    label: 'app_wasm_subpath',
    workspacePath: 'app_wasm_subpath_web',
    expectedBase: '<base href="/web_example/">',
  );

  // Tier 2 (flutter_web_bundle) falling back to the rule's built-in index.html
  // template, with a non-default base_href.
  checkIndex(
    label: 'app_js',
    workspacePath: 'app_js_web',
    expectedBase: '<base href="/web_example_js/">',
  );

  check.finish('All web index.html substitution checks passed.');
}
