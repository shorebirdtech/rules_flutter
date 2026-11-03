/// Reading Apple property lists with `plutil`.
library;

import 'dart:convert';
import 'dart:io';

/// A property list, as the JSON `plutil` converts it to.
///
/// Reads XML and binary plists alike, which is why it goes through `plutil`
/// and not an XML parser: a built `Info.plist` is in Apple's binary format.
/// Dates and data values have no JSON form, so a plist holding either cannot
/// be read.
class Plist {
  /// A plist holding [values].
  const Plist(this.values);

  /// The plist at [path].
  ///
  /// Throws a [ProcessException] if `plutil` cannot read it.
  factory Plist.read(String path) => Plist(_toJson(path));

  /// The plist written as XML in [xml].
  ///
  /// Throws a [ProcessException] if `plutil` cannot read it.
  factory Plist.parseXml(String xml) {
    final dir = Directory.systemTemp.createTempSync('plist_parse');
    try {
      final file = File('${dir.path}/in.plist')..writeAsStringSync(xml);
      return Plist(_toJson(file.path));
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  /// The top-level dictionary.
  final Map<String, Object?> values;

  /// The value of [key], or null if the plist has none.
  Object? operator [](String key) => values[key];

  /// The dictionary at [key], or null if the value is not one.
  Map<String, Object?>? dictionary(String key) {
    final value = values[key];
    return value is Map ? value.cast<String, Object?>() : null;
  }

  /// The plist at [path] rendered as XML text, for checks that look for a
  /// string anywhere in it.
  ///
  /// Throws a [ProcessException] if `plutil` cannot read it.
  static String readXml(String path) =>
      _plutil(['-convert', 'xml1', '-o', '-', path]);

  static Map<String, Object?> _toJson(String path) {
    final json = _plutil(['-convert', 'json', '-o', '-', path]);
    return jsonDecode(json) as Map<String, Object?>;
  }

  static String _plutil(List<String> args) {
    final result = Process.runSync(
      'plutil',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'plutil',
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }
    return result.stdout as String;
  }
}
