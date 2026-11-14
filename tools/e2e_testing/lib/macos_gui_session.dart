/// The macOS session probe and hold, as the e2e workspaces' tests import them.
///
/// The code is `//tools/macos_gui_session`'s: the integration test runner uses
/// it too, and it ships, which this package does not.
library;

export 'package:rules_flutter_macos_gui_session/macos_gui_session.dart';
