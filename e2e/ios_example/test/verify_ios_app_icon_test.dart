/// Verifies that the `.ipa` built from `:app` ships the app icon
/// `flutter create` left in the tree.
///
/// Nothing in this workspace's BUILD file asks for one:
/// `flutter create --platforms=ios .` writes
/// `ios/Runner/Assets.xcassets/AppIcon.appiconset`, and `flutter_ios_app`
/// discovers it the same way it discovers `Runner.entitlements` and the launch
/// storyboard — so an app that has never thought about its icon ships the one
/// it already has, as `flutter build ios` does from the same tree.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'app.ipa',
    appName: 'app',
    prefix: 'ios_app_icon_',
  );
  try {
    // The compiled catalog, which is what a build that forwarded the icons as
    // plain resources would also produce.
    final check = bundle.check
      ..exists('Assets.car', '${bundle.path}/Assets.car');

    // And the loose `AppIcon*.png` variants actool writes only when it has
    // been told which set is the *app icon* — a distinction `resources` alone
    // cannot make.
    final icons =
        bundle.rootFiles
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.startsWith('AppIcon') && n.endsWith('.png'))
            .toList()
          ..sort();
    check.expect(
      icons.join(', '),
      condition: icons.isNotEmpty,
      detail:
          'no AppIcon*.png in the bundle. actool compiled the catalog '
          'without being told which set is the app icon.',
    );

    bundle.finish('PASS: the iOS bundle ships the app icon from the tree');
  } finally {
    bundle.dispose();
  }
}
