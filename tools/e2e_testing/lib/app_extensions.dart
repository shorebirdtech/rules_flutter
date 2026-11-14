/// The app extensions embedded in a built Apple app.
library;

import 'dart:io';

import 'bundle_check.dart';
import 'plist.dart';

/// The `.appex` bundles an app should embed, and the extension point each
/// should declare.
class EmbeddedExtensions {
  /// Expects [expected], which maps each bundle's file name (`share.appex`)
  /// to the extension point its `Info.plist` names
  /// (`com.apple.share-services`), in [plugIns], the app's `PlugIns/`
  /// directory.
  EmbeddedExtensions(this.plugIns, this.expected);

  /// The directory holding the extension bundles.
  final String plugIns;

  /// Each expected bundle's name and extension point.
  final Map<String, String> expected;

  /// The path of the bundle [name].
  String bundle(String name) => '$plugIns/$name';

  /// Passes if [plugIns] holds exactly the expected bundles.
  void checkEmbedded(BundleCheck check) {
    final dir = Directory(plugIns);
    if (!dir.existsSync()) {
      check.fail('$plugIns does not exist, expected ${expected.keys}');
      return;
    }
    final embedded = dir
        .listSync()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toSet();
    check.expect(
      'PlugIns/ holds ${expected.keys.join(', ')}',
      condition:
          embedded.containsAll(expected.keys) &&
          embedded.length == expected.length,
      detail: 'PlugIns/ holds $embedded, expected ${expected.keys}',
    );
  }

  /// Passes for each expected bundle whose `Info.plist` names its extension
  /// point. [infoPlist] gives the path of that file from the bundle's path,
  /// which differs by platform.
  void checkExtensionPoints(
    BundleCheck check, {
    required String Function(String bundle) infoPlist,
  }) {
    for (final MapEntry(key: name, value: point) in expected.entries) {
      final path = infoPlist(bundle(name));
      if (!File(path).existsSync()) {
        check.fail('$name has no Info.plist: $path');
        continue;
      }
      final actual = Plist.read(path).dictionary(
        'NSExtension',
      )?['NSExtensionPointIdentifier'];
      check.expect(
        '$name is a $point extension',
        condition: actual == point,
        detail: '$name names extension point $actual, expected $point',
      );
    }
  }
}
