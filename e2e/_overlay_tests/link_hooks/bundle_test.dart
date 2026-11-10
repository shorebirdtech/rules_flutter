// The release bundle carries the index `glyphs`' link hook wrote, at the key
// `rootBundle` loads it by, and lists it in the asset manifest; the declared
// glyphs the app uses and not the other; and the app package's own declared
// asset, which no hook handles.
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  // The app's files; the bundle is the `_flutter_assets` one.
  final path = args.singleWhere((p) => p.endsWith('_flutter_assets'));
  final bundle = runfiles.rlocation(path);
  if (bundle == null) throw StateError('no runfiles entry for $path');

  final index = File('$bundle/packages/glyphs/glyphs/index.json');
  final names = jsonDecode(index.readAsStringSync());
  if (names is! List || names.join(',') != 'heart,star') {
    throw StateError('index is $names, want [heart, star]');
  }

  for (final glyph in ['heart', 'star']) {
    final file = File('$bundle/packages/glyphs/glyphs/$glyph.txt');
    if (file.readAsStringSync().trim() != 'glyph:$glyph') {
      throw StateError('${file.path} does not hold glyph $glyph');
    }
  }
  if (File('$bundle/packages/glyphs/glyphs/moon.txt').existsSync()) {
    throw StateError('the unused glyph moon shipped');
  }
  final greeting = File('$bundle/packages/link_hooks/greeting.txt');
  if (greeting.readAsStringSync().trim() != 'hello from link_hooks') {
    throw StateError('${greeting.path} does not hold the greeting');
  }

  // The `.json` is the base64 of the binary manifest; the key is stored as
  // plain text inside it.
  final manifest = utf8.decode(
    base64.decode(
      jsonDecode(File('$bundle/AssetManifest.bin.json').readAsStringSync())
          as String,
    ),
    allowMalformed: true,
  );
  if (!manifest.contains('packages/glyphs/glyphs/index.json')) {
    throw StateError('AssetManifest does not list the index');
  }
}
