/// Stands in for Flutter's `font-subset`, which `generate_asset_manifest.dart`
/// runs as `font-subset <output> <input>` with the code points to keep on one
/// line of stdin.
///
/// The "subset" it writes is the text `subset(<input contents>): <code
/// points>`, so a test can read off which code points reached which font. It
/// exits 1 when the input font says `unsubsettable`, as the real tool does for
/// a font it cannot parse.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final output = args[0];
  final input = File(args[1]).readAsStringSync();
  final codePoints = await stdin.transform(utf8.decoder).join();
  if (input.contains('unsubsettable')) {
    stderr.writeln('cannot subset $input');
    exit(1);
  }
  File(output).writeAsStringSync('subset($input): ${codePoints.trim()}');
}
