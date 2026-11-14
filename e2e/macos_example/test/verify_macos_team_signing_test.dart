/// Verifies the team-signed `:app_extensions_team`: the app and every
/// extension are signed by one team, none ad hoc, every App Group is that
/// team's prefixed form, and the signature over the whole bundle is valid.
///
/// rules_apple signs each extension in its own target, so the app's profile
/// does not reach its extensions. An extension without a profile of its own
/// is signed ad hoc inside an otherwise team-signed app, has no team, and
/// macOS refuses it the team's App Group.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/macos_bundle.dart';
import 'package:rules_flutter_e2e_testing/signing.dart';

void main() {
  final bundle = MacosBundle.fromRunfiles(
    'app_extensions_team.zip',
    appName: 'Extensions App',
    prefix: 'macos_team_signing_',
    preserveSignature: true,
  );
  try {
    final check = bundle.check;
    CodeSignature(bundle.path).checkValid(check);

    final bundles = [
      bundle.path,
      ...Directory('${bundle.contents}/PlugIns')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path)
          .where((p) => p.endsWith('.appex')),
    ];
    check.expect(
      'the app and two extensions are present',
      condition: bundles.length == 3,
      detail: 'expected the app and two extensions, found $bundles',
    );

    final teams = <String>{};
    for (final path in bundles) {
      final name = path.split('/').last;
      final team = CodeSignature(path).teamIdentifier;
      if (team == null) {
        check.fail('$name is signed ad hoc, with no TeamIdentifier');
        continue;
      }
      teams.add(team);
      check.pass('$name is signed by team $team');

      final groups = Entitlements.fromSignature(path).applicationGroups;
      check.expect(
        '$name is in $groups',
        condition:
            groups != null &&
            groups.isNotEmpty &&
            groups.every((g) => g is String && g.startsWith('$team.')),
        detail: '$name has App Groups $groups, expected ones prefixed $team.',
      );
    }
    check.expect(
      'the bundles are signed by one team',
      condition: teams.length <= 1,
      detail: 'the bundles are signed by different teams: $teams',
    );

    bundle.finish('\nAll macOS team signing checks passed.');
  } finally {
    bundle.dispose();
  }
}
