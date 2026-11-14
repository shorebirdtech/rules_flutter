/// Property: an app built with `--no-strip` in `extra_gen_snapshot_options`
/// ships `App.framework/App` with its local symbols, as
/// `flutter build macos --release --extra-gen-snapshot-options=--no-strip`
/// does.
///
/// The default app is the control: it is stripped, so the other keeping its
/// symbols is the option and not a binary that never had any.
///
/// Run once for each `-c` that builds Flutter's release mode (see the BUILD
/// file).
library;

import 'package:rules_flutter_e2e_testing/apple_release.dart';
import 'package:rules_flutter_e2e_testing/macos_bundle.dart';

void main() {
  final stripped = MacosBundle.fromRunfiles(
    'app.zip',
    appName: 'Flutter App',
    prefix: 'stripped_bundle_test',
  );
  final kept = MacosBundle.fromRunfiles(
    'app_no_strip.zip',
    appName: 'Flutter App',
    prefix: 'no_strip_bundle_test',
  );
  try {
    const binary = 'App.framework/App';
    checkAppBinaryStripped(stripped.check, '${stripped.frameworks}/$binary');
    checkAppBinaryKeepsSymbols(kept.check, '${kept.frameworks}/$binary');
    stripped.finish('Control: the default App binary is stripped.');
    kept.finish('The --no-strip App binary keeps its symbols.');
  } finally {
    stripped.dispose();
    kept.dispose();
  }
}
