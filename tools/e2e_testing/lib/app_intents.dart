/// The App Intents metadata a built Apple bundle carries.
library;

import 'dart:io';

import 'bundle_check.dart';

/// The metadata `flutter_ios_app` and `flutter_macos_app` extract for an App
/// Intents library, `Metadata.appintents/extract.actionsdata`.
class AppIntentsMetadata {
  /// The metadata in [resources], the directory that holds
  /// `Metadata.appintents`: the bundle root on iOS, `Contents/Resources` on
  /// macOS.
  AppIntentsMetadata(String resources)
    : actionsData = File('$resources/Metadata.appintents/extract.actionsdata');

  /// The metadata file.
  final File actionsData;

  /// Passes if the metadata exists and names [intent]. [owner] says whose it
  /// is, as in "widgets.appex".
  void checkNames(BundleCheck check, String intent, {required String owner}) {
    if (!actionsData.existsSync()) {
      check.fail('$owner has no extract.actionsdata: ${actionsData.path}');
      return;
    }
    check.expect(
      '$owner carries App Intents metadata naming $intent',
      condition: actionsData.readAsStringSync().contains(intent),
      detail: '${actionsData.path} does not name $intent',
    );
  }
}
