/// The `ipa_post_processor` of an iOS app built in release or profile:
/// removes from `Payload/<App>.app/Frameworks/` the framework of each code
/// asset a link hook dropped, before rules_apple signs the app.
///
/// rules_apple embeds every framework it knows when the app is analysed, and
/// which code assets ship is known only once the hooks have run, so the app
/// embeds every candidate and carries the list of those to remove
/// (`rules_flutter_dropped_frameworks.txt`, written by `code_assets.dart
/// ios-dropped-frameworks`). This reads the list from the app, deletes each
/// framework it names and the list itself. An app without the list fails:
/// the processor was attached to an app it was not written for.
///
/// rules_apple runs it as `<processor> <work dir>`, with no runfiles, so it
/// is compiled to a self-contained executable.
///
/// On a device build rules_apple then signs `Frameworks/` by listing it, and
/// warns that frameworks it was told were signed are missing: those are the
/// ones removed here, and the warning is expected.
library;

import 'dart:io';

/// The list's name in the app; `iosDroppedFrameworksFile` in
/// `code_assets.dart`, which writes it.
const droppedFrameworksFile = 'rules_flutter_dropped_frameworks.txt';

/// Removes the frameworks [workDir]'s apps list, and the lists. Returns what
/// it removed, as `<App>.app/Frameworks/<name>.framework`.
List<String> removeDroppedFrameworks(Directory workDir) {
  final payload = Directory('${workDir.path}/Payload');
  final apps = payload.existsSync()
      ? [
          for (final entry in payload.listSync())
            if (entry is Directory && entry.path.endsWith('.app')) entry,
        ]
      : const <Directory>[];
  if (apps.isEmpty) {
    throw StateError('no Payload/*.app in ${workDir.path}');
  }
  final removed = <String>[];
  for (final app in apps) {
    final list = File('${app.path}/$droppedFrameworksFile');
    final appName = app.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (!list.existsSync()) {
      throw StateError(
        '$appName has no $droppedFrameworksFile: this post-processor is for '
        'an app flutter_ios_app or flutter_ios_dropped_frameworks_gen made',
      );
    }
    for (final name in list.readAsLinesSync()) {
      if (name.isEmpty) continue;
      if (!name.endsWith('.framework') || name.contains('/')) {
        throw StateError('$droppedFrameworksFile names `$name`');
      }
      final framework = Directory('${app.path}/Frameworks/$name');
      if (framework.existsSync()) {
        framework.deleteSync(recursive: true);
        removed.add('$appName/Frameworks/$name');
      }
    }
    list.deleteSync();
  }
  return removed;
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: ios_code_asset_post_processor <work dir>');
    exitCode = 64;
    return;
  }
  try {
    for (final removed in removeDroppedFrameworks(Directory(args.single))) {
      stdout.writeln('removed $removed, a code asset no link hook kept');
    }
  } on StateError catch (e) {
    stderr.writeln('ios_code_asset_post_processor: ${e.message}');
    exitCode = 1;
  }
}
