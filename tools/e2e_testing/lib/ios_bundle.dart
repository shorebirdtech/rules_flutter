/// Checks on a built iOS `.app`, in the `.ipa` `flutter_ios_app` produces.
library;

import 'dart:io';

import 'archive.dart';
import 'bundle_check.dart';

/// An iOS app bundle unpacked from its `.ipa`.
class IosBundle {
  IosBundle._(this._archive, this.path, this.check);

  /// Unpacks the `.ipa` at [ipa] (a workspace path) and finds the app in its
  /// `Payload/`: `<appName>.app`, or, without [appName], the only `.app`
  /// there. Call [dispose] when done.
  ///
  /// Exits 1 if the archive is missing, and throws a [StateError] if
  /// `Payload/` does not hold the app.
  factory IosBundle.fromRunfiles(
    String ipa, {
    String? appName,
    String prefix = 'ios_bundle_test',
  }) {
    final archive = ExtractedArchive.fromRunfiles(ipa, prefix: prefix);
    try {
      return IosBundle._(
        archive,
        _findApp('${archive.path}/Payload', appName),
        BundleCheck(),
      );
    } on StateError {
      archive.dispose();
      rethrow;
    }
  }

  static String _findApp(String payload, String? appName) {
    if (appName != null) {
      final app = '$payload/$appName.app';
      if (!Directory(app).existsSync()) {
        throw StateError('.app not found at $app');
      }
      return app;
    }
    final apps = [
      for (final entity in Directory(payload).listSync())
        if (entity is Directory && entity.path.endsWith('.app')) entity.path,
    ];
    if (apps.length != 1) {
      throw StateError('expected one .app in $payload, found $apps');
    }
    return apps.single;
  }

  final ExtractedArchive _archive;

  /// The `.app` directory.
  final String path;

  /// Where checks are recorded.
  final BundleCheck check;

  /// `Info.plist`.
  String get infoPlist => '$path/Info.plist';

  /// `PlugIns/`, where the app's extensions are embedded.
  String get plugIns => '$path/PlugIns';

  /// The files at the bundle's top level: the runner, and in a debug build
  /// its `.debug.dylib` beside it.
  List<File> get rootFiles =>
      Directory(path).listSync().whereType<File>().toList();

  /// Deletes the unpacked files.
  void dispose() => _archive.dispose();

  /// Ends the test: prints [success] if every check passed; otherwise lists
  /// the bundle (without descending into frameworks or extensions) and exits
  /// 1.
  void finish(String success) {
    check.finish(
      success,
      onFailure: () {
        stderr.writeln('Bundle contents:');
        check.listTree(
          Directory(path),
          descend: (dir) =>
              !dir.path.endsWith('.framework') && !dir.path.endsWith('.appex'),
        );
        dispose();
      },
    );
  }
}
