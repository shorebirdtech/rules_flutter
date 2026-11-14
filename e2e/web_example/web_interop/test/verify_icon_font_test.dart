/// Reads the icon font a release web bundle ships, and checks which glyphs it
/// kept.
///
/// A release build subsets `MaterialIcons` to the icons the app uses, so an
/// icon the subset misses draws as a blank box in the shipped app, and nothing
/// fails at build time. This test reads the shipped font's character map, which
/// is what the browser looks glyphs up in, rather than anything about how the
/// build found the icons.
///
/// Arguments (the test's `args`):
///
///  - `--bundle=PATH`: the bundle directory in the runfiles, such as
///    `web_interop/glyph_app_web`.
///  - `--keeps=HEX,HEX`: code points that must have a glyph.
///  - `--lacks=HEX,HEX`: code points that must not. They prove the font was
///    subset at all: an unshaken font keeps everything and would pass every
///    `--keeps`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/font_glyphs.dart';
import 'package:rules_flutter_e2e_testing/web_bundle.dart';

List<int> _hexList(String? list) => [
  for (final item in (list ?? '').split(','))
    if (item.isNotEmpty) int.parse(item, radix: 16),
];

String _hex(int codePoint) => 'U+${codePoint.toRadixString(16).toUpperCase()}';

void main(List<String> args) {
  final options = {
    for (final arg in args)
      if (arg.startsWith('--') && arg.contains('='))
        arg.substring(2, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1),
  };
  final bundlePath = options['bundle'];
  if (bundlePath == null) {
    stderr.writeln('missing --bundle=<runfiles path>');
    exit(2);
  }
  final keeps = _hexList(options['keeps']);
  final lacks = _hexList(options['lacks']);

  final check = BundleCheck();
  final bundle = WebBundle.fromRunfiles(bundlePath, check);

  final manifest = bundle.read('assets/FontManifest.json');
  if (manifest == null) return check.finish('');
  final families = (jsonDecode(manifest) as List).cast<Map<String, Object?>>();
  final material = families.where((f) => f['family'] == 'MaterialIcons');
  check.expect(
    'the FontManifest lists MaterialIcons',
    condition: material.isNotEmpty,
    detail: 'families: ${[for (final f in families) f['family']]}',
  );
  if (material.isEmpty) return check.finish('');
  final fonts = (material.first['fonts']! as List).cast<Map<String, Object?>>();
  final font = bundle.requireFile('assets/${fonts.first['asset']}');
  if (font == null) return check.finish('');

  final glyphs = fontCodePoints(font.readAsBytesSync());
  for (final codePoint in keeps) {
    check.expect(
      '${_hex(codePoint)} has a glyph in the shipped MaterialIcons',
      condition: glyphs.contains(codePoint),
      detail:
          'the shipped font has no glyph for it, so text drawn with it shows '
          'as a blank box. The font keeps ${glyphs.length} glyphs: '
          '${(glyphs.toList()..sort()).map(_hex).take(12).join(', ')}',
    );
  }
  for (final codePoint in lacks) {
    check.expect(
      '${_hex(codePoint)} was cut from the shipped MaterialIcons',
      condition: !glyphs.contains(codePoint),
      detail: 'the font was not subset to the icons the app uses',
    );
  }
  check.finish('$bundlePath: the shipped icon font is as expected');
}
