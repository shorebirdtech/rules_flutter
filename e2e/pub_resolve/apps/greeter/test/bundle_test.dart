/// Verifies a path package's asset reaches the web bundle under the key Flutter
/// gives a package's asset, `packages/<package>/<path>`, and not at a bare path.
library;

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

void main() {
  final check = BundleCheck();
  final bundle = WebBundle.fromRunfiles(
    'apps/greeter/greeter_web',
    check,
    label: 'greeter',
  );

  check.exists(
    'the path package\'s asset under its package',
    '${bundle.path}/assets/packages/greeting/assets/greeting.txt',
    nonEmpty: true,
  );
  check.absent(
    'the asset at a bare path',
    '${bundle.path}/assets/assets/greeting.txt',
  );

  check.finish('The path package\'s asset is bundled as flutter build would.');
}
