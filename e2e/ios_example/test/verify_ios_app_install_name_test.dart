/// Property: the `App.framework/App` an iOS build assembles has the install
/// name `flutter build ios` gives it, `@rpath/App.framework/App`, in debug
/// mode (the stub binary) as in release (the AOT snapshot).
///
/// A host app that links the framework records the install name, and the
/// dynamic linker resolves it through the app's rpaths at launch.
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';

void main() {
  final check = BundleCheck();
  checkAppInstallName(check, runfilesAppBinary());
  check.finish('The App binary has the install name flutter build gives it.');
}
