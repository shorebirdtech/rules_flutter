/// Merges permissions into a main (base) AndroidManifest.xml: an overlay's,
/// and those of the app's Android libraries, and qualifies its component
/// class names. Three callers, one mechanism:
///
///   * `flutter_android_app`'s debug variant handling, folding
///     `android/app/src/debug/AndroidManifest.xml` into `-c dbg` APKs the
///     way Gradle's manifest merger does;
///   * `flutter_android_app(permissions = [...])`, folding the app's own
///     permissions in for **every** compilation mode — the seam a networked
///     app needs, since the debug variant's INTERNET is the Dart VM
///     service's and never reaches release;
///   * library permissions (`--library`, repeatable): a plugin or AAR that
///     declares `<uses-permission>` in its own manifest. Gradle merges those
///     into the app; Bazel's merger drops them unless
///     `--merge_android_manifest_permissions` is set, so an app that forgot
///     the flag shipped without them. Lifting them here makes the flag moot.
///
/// This tool implements deliberately narrow, never-wrong semantics: the
/// overlay may contain ONLY `<uses-permission>` / `<uses-permission-sdk-23>`
/// elements carrying exactly an `android:name` attribute (plus comments and
/// whitespace). Anything else — other elements, other attributes, text
/// content, `${...}` Gradle placeholders — is a hard error naming the
/// offending construct, so an overlay this tool cannot faithfully merge can
/// never be silently mis-merged. Users with richer variant manifests pass
/// `debug_manifest` on `flutter_android_app` explicitly (or restructure).
///
/// A library manifest is read leniently, since it is a whole manifest: only
/// the `<uses-permission>` / `<uses-permission-sdk-23>` elements directly
/// under its root are taken. Their `android:*` attributes (`maxSdkVersion`,
/// `usesPermissionFlags`) are kept; `tools:*` lint hints are dropped; an
/// element marked `tools:node="remove"` is a removal directive, not a
/// declaration, and is skipped. A `\${name}` placeholder passes through
/// verbatim when `name` is one the app's build substitutes afterwards
/// (`--placeholder`, e.g. androidx.core's `\${applicationId}.…` permission);
/// any other is a hard error.
///
/// Component class names (`--namespace`): a manifest names its activities,
/// services, receivers and providers relative to the app's code package
/// (`.MainActivity`), which Gradle calls the `namespace` and which is not the
/// application id. `flutter create` sets the two equal, but one runner may
/// ship under any number of application ids, and a name left relative is
/// resolved against the application id, where there is no such class. So
/// each relative name is written out in full against the namespace, as AGP's
/// manifest merger does (`XmlAttribute` in com.android.manifmerger): a name
/// that starts with a dot or has none (`.X`, `.a.X`, `X`) becomes
/// `<namespace>.X`, `<namespace>.a.X`, `<namespace>.X`; any other is already
/// qualified. Without `--namespace` the names are left as they are.
///
/// The app's version (`--version-code`, `--version-name`): Gradle writes
/// `android:versionCode` and `android:versionName` onto the root
/// `<manifest>` from `flutter.versionCode` and `flutter.versionName`, and so
/// does this tool, from `flutter_android_app`'s `build_number` and
/// `build_name`. A base that declares either attribute itself conflicts with
/// a value the app sets, which is an error; `--default-version-code` and
/// `--default-version-name` give the value used only when the base declares
/// none, for an app that leaves the arguments unset.
///
/// Uncompressed native libraries (`--uncompressed-native-libs`): AGP stores
/// an app's native libraries uncompressed and page-aligned when its minimum
/// SDK is 23 or more (`jniLibs.useLegacyPackaging = false`, the default), and
/// sets `android:extractNativeLibs="false"` on `<application>` so the
/// installer leaves them in the APK; so does this tool. A base that declares
/// `"true"` asks for the legacy packaging, which these rules do not build,
/// and is an error.
///
/// The base manifest is never re-serialized: merged permissions are inserted
/// textually right after the root `<manifest ...>` open tag, and qualified
/// class names replace their attribute values in place, so every other base
/// byte passes through untouched.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart merge_android_manifests.dart --base <path> [--overlay <path>]
///       [--library <path>]... [--placeholder <name>]... [--namespace <package>]
///       [--version-code <n> | --default-version-code <n>]
///       [--version-name <s> | --default-version-name <s>]
///       [--uncompressed-native-libs] --output <path>
import 'dart:io';

/// Pointer at the Tier-1 escape hatch, appended to every rejection.
const _escapeHatch =
    'If the overlay needs constructs this merger does not '
    'support, pass an explicit merged manifest via the `debug_manifest` '
    'attribute of `flutter_android_app` instead.';

/// The overlay element names whose permissions we merge.
const _permissionElements = {'uses-permission', 'uses-permission-sdk-23'};

/// A permission declaration parsed from the overlay.
class OverlayPermission {
  /// `uses-permission` or `uses-permission-sdk-23`.
  final String element;

  /// The `android:name` value, e.g. `android.permission.INTERNET`.
  final String name;

  OverlayPermission(this.element, this.name);
}

Never _reject(String overlayPath, String detail) {
  throw FormatException(
    'Cannot merge debug variant manifest $overlayPath: $detail\n'
    '$_escapeHatch',
  );
}

/// Minimal strict XML scanner shared by the overlay parser and the base
/// open-tag locator. Understands only what these manifests need: the XML
/// declaration, comments, and start/end/self-closing tags with
/// double-or-single-quoted attributes.
class _Scanner {
  final String text;
  int pos = 0;

  _Scanner(this.text);

  bool get atEnd => pos >= text.length;

  /// Consumes whitespace, comments, and (at position 0) the XML declaration.
  void skipInsignificant() {
    while (!atEnd) {
      final c = text[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        pos++;
      } else if (text.startsWith('<!--', pos)) {
        final end = text.indexOf('-->', pos + 4);
        if (end == -1) {
          throw const FormatException('unterminated comment');
        }
        pos = end + 3;
      } else if (pos == 0 && text.startsWith('<?xml', pos)) {
        final end = text.indexOf('?>', pos);
        if (end == -1) {
          throw const FormatException('unterminated XML declaration');
        }
        pos = end + 2;
      } else {
        break;
      }
    }
  }

  /// Parses a tag at the current position (which must be `<`). Returns
  /// (name, attributes, selfClosing, isEndTag). Attribute order is
  /// preserved; duplicate attribute names are an error.
  (String, Map<String, String>, bool, bool) readTag() {
    if (atEnd || text[pos] != '<') {
      throw FormatException('expected a tag at offset $pos');
    }
    pos++;
    var isEndTag = false;
    if (!atEnd && text[pos] == '/') {
      isEndTag = true;
      pos++;
    }
    final name = _readName();
    final attributes = <String, String>{};
    while (true) {
      _skipSpaces();
      if (atEnd) throw FormatException('unterminated tag <$name');
      if (text[pos] == '>') {
        pos++;
        return (name, attributes, false, isEndTag);
      }
      if (text.startsWith('/>', pos)) {
        pos += 2;
        return (name, attributes, true, isEndTag);
      }
      final attrName = _readName();
      _skipSpaces();
      if (atEnd || text[pos] != '=') {
        throw FormatException('attribute $attrName in <$name> has no value');
      }
      pos++;
      _skipSpaces();
      if (atEnd || (text[pos] != '"' && text[pos] != "'")) {
        throw FormatException(
          'attribute $attrName in <$name> has an unquoted value',
        );
      }
      final quote = text[pos];
      pos++;
      final end = text.indexOf(quote, pos);
      if (end == -1) {
        throw FormatException(
          'attribute $attrName in <$name> has an unterminated value',
        );
      }
      if (attributes.containsKey(attrName)) {
        throw FormatException('duplicate attribute $attrName in <$name>');
      }
      attributes[attrName] = text.substring(pos, end);
      pos = end + 1;
    }
  }

  void _skipSpaces() {
    while (!atEnd &&
        (text[pos] == ' ' ||
            text[pos] == '\t' ||
            text[pos] == '\r' ||
            text[pos] == '\n')) {
      pos++;
    }
  }

  String _readName() {
    final start = pos;
    while (!atEnd && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(text[pos])) {
      pos++;
    }
    if (pos == start) {
      throw FormatException('malformed tag at offset $start');
    }
    return text.substring(start, pos);
  }
}

/// Parses the overlay under the strict contract documented at the top of
/// this file. Throws [FormatException] on any construct outside it.
List<OverlayPermission> parseOverlayPermissions(
  String overlayXml,
  String overlayPath,
) {
  final scanner = _Scanner(overlayXml);

  Never rejectAt(String detail) => _reject(overlayPath, detail);

  void checkNoPlaceholder(String value, String context) {
    if (value.contains(r'${')) {
      rejectAt(
        '$context contains a Gradle placeholder token "$value"; '
        'placeholders are not substituted by rules_flutter.',
      );
    }
  }

  scanner.skipInsignificant();
  if (scanner.atEnd) rejectAt('the overlay has no root element.');
  final (rootName, rootAttrs, rootSelfClosing, rootIsEnd) = scanner.readTag();
  if (rootIsEnd || rootName != 'manifest') {
    rejectAt('the root element must be <manifest>, found <$rootName>.');
  }
  for (final entry in rootAttrs.entries) {
    if (entry.key != 'xmlns' && !entry.key.startsWith('xmlns:')) {
      rejectAt(
        'the <manifest> root carries attribute "${entry.key}"; only '
        'xmlns:* namespace declarations are supported.',
      );
    }
    checkNoPlaceholder(entry.value, 'the "${entry.key}" attribute');
  }

  final permissions = <OverlayPermission>[];
  if (rootSelfClosing) {
    _requireOnlyTrailingInsignificant(scanner, rejectAt);
    return permissions;
  }

  while (true) {
    scanner.skipInsignificant();
    if (scanner.atEnd) {
      rejectAt('the overlay is missing its </manifest> close tag.');
    }
    if (scanner.text[scanner.pos] != '<') {
      final text = scanner.text.substring(scanner.pos).trim();
      final excerpt = text.length > 40 ? '${text.substring(0, 40)}…' : text;
      rejectAt(
        'unexpected text content "$excerpt"; only <uses-permission> '
        'elements, comments, and whitespace are supported.',
      );
    }
    final (name, attrs, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      if (name != 'manifest') {
        rejectAt('unexpected close tag </$name>.');
      }
      _requireOnlyTrailingInsignificant(scanner, rejectAt);
      return permissions;
    }
    if (!_permissionElements.contains(name)) {
      rejectAt(
        'element <$name> is not supported; only <uses-permission> '
        'and <uses-permission-sdk-23> may appear.',
      );
    }
    if (attrs.length != 1 || !attrs.containsKey('android:name')) {
      final extras = attrs.keys.where((k) => k != 'android:name');
      if (extras.isNotEmpty) {
        rejectAt(
          '<$name> carries attribute "${extras.first}"; exactly one '
          'android:name attribute is supported.',
        );
      }
      rejectAt('<$name> is missing its android:name attribute.');
    }
    final value = attrs['android:name']!;
    checkNoPlaceholder(value, 'the android:name attribute');
    if (value.isEmpty) {
      rejectAt('<$name> has an empty android:name attribute.');
    }
    permissions.add(OverlayPermission(name, value));
    if (!selfClosing) {
      // Allow only an immediately-following matching close tag (with
      // insignificant content between) — permission elements have no body.
      scanner.skipInsignificant();
      final (closeName, closeAttrs, _, closeIsEnd) = scanner.readTag();
      if (!closeIsEnd || closeName != name || closeAttrs.isNotEmpty) {
        rejectAt('<$name> must be empty; found nested content.');
      }
    }
  }
}

void _requireOnlyTrailingInsignificant(
  _Scanner scanner,
  Never Function(String) rejectAt,
) {
  scanner.skipInsignificant();
  if (!scanner.atEnd) {
    rejectAt('unexpected content after </manifest>.');
  }
}

/// Locates the root `<manifest ...>` open tag in [baseXml] and returns the
/// offset just past its `>`. Throws [FormatException] when the base has no
/// non-self-closing `<manifest>` root to insert into.
int _baseInsertionPoint(String baseXml, String basePath) {
  final scanner = _Scanner(baseXml);
  scanner.skipInsignificant();
  if (scanner.atEnd) {
    throw FormatException('base manifest $basePath is empty.');
  }
  final (name, _, selfClosing, isEnd) = scanner.readTag();
  if (isEnd || name != 'manifest') {
    throw FormatException(
      'base manifest $basePath has root element <$name>, not <manifest>.',
    );
  }
  if (selfClosing) {
    throw FormatException(
      'base manifest $basePath has a self-closing <manifest/> root; '
      'there is no element body to merge permissions into.',
    );
  }
  return scanner.pos;
}

/// The `android:name` values of every `<uses-permission>` /
/// `<uses-permission-sdk-23>` the base already declares. Comments are
/// excluded; the rest of the base is scanned leniently (we only need names,
/// never a full parse).
Set<String> _basePermissionNames(String baseXml) {
  final withoutComments = baseXml.replaceAll(
    RegExp(r'<!--.*?-->', dotAll: true),
    '',
  );
  final names = <String>{};
  final tag = RegExp(r'<uses-permission(?:-sdk-23)?[\s/>]([^>]*)>?');
  final nameAttr = RegExp('android:name\\s*=\\s*["\']([^"\']*)["\']');
  for (final match in tag.allMatches(withoutComments)) {
    final attrText = match.group(1) ?? '';
    final name = nameAttr.firstMatch(attrText)?.group(1);
    if (name != null) names.add(name);
  }
  return names;
}

/// A `<uses-permission>` taken from a library manifest, with the `android:*`
/// attributes it is emitted with.
class LibraryPermission {
  /// `uses-permission` or `uses-permission-sdk-23`.
  final String element;

  /// The `android:*` attributes, `android:name` among them, in source order.
  final Map<String, String> attributes;

  LibraryPermission(this.element, this.attributes);

  String get name => attributes['android:name']!;

  String render() {
    final attrs = attributes.entries
        .map((e) => ' ${e.key}="${e.value}"')
        .join();
    return '<$element$attrs/>';
  }
}

/// The permissions [libraryXml] declares directly under its `<manifest>`
/// root, read as documented at the top of this file.
List<LibraryPermission> parseLibraryPermissions(
  String libraryXml,
  String libraryPath, {
  Set<String> placeholders = const {},
}) {
  Never reject(String detail) => throw FormatException(
    'Cannot read the permissions of library manifest $libraryPath: $detail',
  );

  final scanner = _Scanner(libraryXml);
  final permissions = <LibraryPermission>[];
  var depth = 0;
  while (true) {
    scanner.skipInsignificant();
    if (scanner.atEnd) break;
    final text = scanner.text;
    if (text[scanner.pos] != '<') {
      final next = text.indexOf('<', scanner.pos);
      scanner.pos = next == -1 ? text.length : next;
      continue;
    }
    if (text.startsWith('<![CDATA[', scanner.pos)) {
      final end = text.indexOf(']]>', scanner.pos);
      if (end == -1) reject('unterminated CDATA section.');
      scanner.pos = end + 3;
      continue;
    }
    if (text.startsWith('<?', scanner.pos) ||
        text.startsWith('<!', scanner.pos)) {
      final end = text.indexOf('>', scanner.pos);
      if (end == -1) reject('unterminated markup at offset ${scanner.pos}.');
      scanner.pos = end + 1;
      continue;
    }
    final (name, attrs, selfClosing, isEnd) = scanner.readTag();
    if (isEnd) {
      depth--;
      continue;
    }
    if (depth == 1 && _permissionElements.contains(name)) {
      if (attrs['tools:node'] == 'remove') {
        // A removal directive for the merger, not a declaration.
      } else {
        final kept = <String, String>{
          for (final e in attrs.entries)
            if (e.key.startsWith('android:')) e.key: e.value,
        };
        for (final e in attrs.entries) {
          if (!e.key.startsWith('android:') && !e.key.startsWith('tools:')) {
            reject(
              '<$name> carries attribute "${e.key}", which is neither '
              'android:* nor tools:*.',
            );
          }
        }
        final permissionName = kept['android:name'];
        if (permissionName == null || permissionName.isEmpty) {
          reject('<$name> has no android:name attribute.');
        }
        for (final value in kept.values) {
          for (final match in RegExp(r'\$\{([^}]*)\}').allMatches(value)) {
            if (!placeholders.contains(match[1])) {
              reject(
                '<$name android:name="$permissionName"> contains the Gradle '
                'placeholder "\${${match[1]}}", which this build does not '
                'substitute (it substitutes: ${placeholders.join(', ')}).',
              );
            }
          }
        }
        permissions.add(LibraryPermission(name, kept));
      }
    }
    if (!selfClosing) depth++;
  }
  return permissions;
}

/// The attributes holding a class name relative to the code package, by
/// element: the package-dependent class references of AGP's manifest model.
const _classAttributes = {
  'application': [
    'android:name',
    'android:backupAgent',
    'android:manageSpaceActivity',
  ],
  'activity': ['android:name', 'android:parentActivityName'],
  'activity-alias': ['android:name', 'android:targetActivity'],
  'service': ['android:name'],
  'receiver': ['android:name'],
  'provider': ['android:name'],
  'instrumentation': ['android:name'],
};

/// [xml] with every relative component class name (`.MainActivity`,
/// `.sub.Receiver` or a bare `MainActivity`) written in full against
/// [namespace], as AGP does. Returns [xml] unchanged when it names none.
String qualifyClassNames(String xml, String namespace) {
  // Comments, CDATA and processing instructions blanked to spaces, so tags
  // are found only in markup and offsets still index into [xml].
  final masked = xml.replaceAllMapped(
    RegExp(r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>', dotAll: true),
    (m) => ' ' * m[0]!.length,
  );
  final tag = RegExp(
    r'''<([A-Za-z][\w.-]*)((?:\s+[\w:.-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*/?>''',
  );
  final attribute = RegExp(r'''([\w:.-]+)\s*=\s*(["'])(.*?)\2''');
  final relative = <({int start, int end, String value})>[];
  for (final t in tag.allMatches(masked)) {
    final names = _classAttributes[t[1]];
    if (names == null) continue;
    final attributesStart = t.start + 1 + t[1]!.length;
    for (final a in attribute.allMatches(t[2]!)) {
      final value = a[3]!;
      // A `${...}` placeholder is the binary's to substitute, not a name.
      if (!names.contains(a[1]) || value.isEmpty || value.contains(r'${')) {
        continue;
      }
      if (value.startsWith('.') || !value.contains('.')) {
        final start = attributesStart + a.start + a[0]!.indexOf(a[2]!) + 1;
        relative.add((start: start, end: start + value.length, value: value));
      }
    }
  }
  if (relative.isEmpty) return xml;

  final out = StringBuffer();
  var at = 0;
  for (final r in relative) {
    out
      ..write(xml.substring(at, r.start))
      ..write(
        r.value.startsWith('.')
            ? '$namespace${r.value}'
            : '$namespace.${r.value}',
      );
    at = r.end;
  }
  out.write(xml.substring(at));
  return out.toString();
}

/// [xml] with `android:extractNativeLibs="false"` on its `<application>`,
/// written first among its attributes. A base that declares it `false`
/// already is returned unchanged; one that declares anything else, or has no
/// `<application>`, is an error.
String markNativeLibsUncompressed(String xml, {required String basePath}) {
  // Comments, CDATA and processing instructions blanked, as in
  // [qualifyClassNames].
  final masked = xml.replaceAllMapped(
    RegExp(r'<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>', dotAll: true),
    (m) => ' ' * m[0]!.length,
  );
  final application = RegExp(
    r'''<application((?:\s+[\w:.-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*/?>''',
  ).firstMatch(masked);
  if (application == null) {
    throw FormatException('The manifest $basePath has no <application>.');
  }
  final declared = RegExp(
    r'''android:extractNativeLibs\s*=\s*(["'])(.*?)\1''',
  ).firstMatch(application[1]!);
  if (declared != null) {
    if (declared[2] == 'false') return xml;
    throw FormatException(
      'The manifest $basePath declares '
      'android:extractNativeLibs="${declared[2]}", but the APK stores its '
      'native libraries uncompressed, as AGP does from a minimum SDK of 23, '
      'so the installer must not extract them. Remove the attribute.',
    );
  }
  final insertAt = application.start + '<application'.length;
  return '${xml.substring(0, insertAt)} android:extractNativeLibs="false"'
      '${xml.substring(insertAt)}';
}

/// A version attribute for the root `<manifest>`: its [value], and whether
/// that is only the default, which a value the base declares replaces.
typedef VersionAttribute = ({String value, bool isDefault});

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// [xml] with `android:versionCode` and `android:versionName` set on its root
/// `<manifest>` from [versionCode] and [versionName]. An attribute the root
/// already declares stays when the value is a default; otherwise it is an
/// error, so neither value is silently lost.
String setVersion(
  String xml, {
  required String basePath,
  VersionAttribute? versionCode,
  VersionAttribute? versionName,
}) {
  final scanner = _Scanner(xml)..skipInsignificant();
  final (_, rootAttributes, _, _) = scanner.readTag();
  final insertAt = scanner.pos - 1;
  final added = StringBuffer();
  for (final (attribute, argument, version) in [
    ('android:versionCode', 'build_number', versionCode),
    ('android:versionName', 'build_name', versionName),
  ]) {
    if (version == null) continue;
    final declared = rootAttributes[attribute];
    if (declared != null) {
      if (version.isDefault) continue;
      throw FormatException(
        'The manifest $basePath declares $attribute="$declared", and '
        '`$argument` sets it to "${version.value}". Remove the attribute '
        'from the manifest, or leave `$argument` unset to keep it.',
      );
    }
    added.write(' $attribute="${_escapeAttribute(version.value)}"');
  }
  if (added.isEmpty) return xml;
  return xml.substring(0, insertAt) +
      added.toString() +
      xml.substring(insertAt);
}

/// Merges [overlayXml]'s permissions into [baseXml], returning the merged
/// manifest text with its class names qualified against [namespace] when
/// given (see [qualifyClassNames]). Throws [FormatException] when the overlay
/// violates the strict contract or the base has no `<manifest>` root.
String mergeManifests({
  required String baseXml,
  required String basePath,
  String? overlayXml,
  String? overlayPath,
  Map<String, String> libraries = const {},
  Set<String> placeholders = const {},
  String? namespace,
  VersionAttribute? versionCode,
  VersionAttribute? versionName,
  bool uncompressedNativeLibs = false,
}) {
  if (namespace != null) baseXml = qualifyClassNames(baseXml, namespace);
  if (uncompressedNativeLibs) {
    baseXml = markNativeLibsUncompressed(baseXml, basePath: basePath);
  }
  if (versionCode != null || versionName != null) {
    _baseInsertionPoint(baseXml, basePath);
    baseXml = setVersion(
      baseXml,
      basePath: basePath,
      versionCode: versionCode,
      versionName: versionName,
    );
  }
  final overlayPermissions = overlayXml == null
      ? const <OverlayPermission>[]
      : parseOverlayPermissions(overlayXml, overlayPath!);
  final insertAt = _baseInsertionPoint(baseXml, basePath);
  final seen = _basePermissionNames(baseXml);

  final lines = <String>[];
  for (final permission in overlayPermissions) {
    if (!seen.add(permission.name)) continue;
    lines.add('<${permission.element} android:name="${permission.name}"/>');
  }
  // Libraries in the order given; the first declaration of a name wins,
  // except that one without maxSdkVersion replaces one with it, since the
  // app then needs the permission at every SDK level.
  final fromLibraries = <String, LibraryPermission>{};
  for (final MapEntry(key: path, value: xml) in libraries.entries) {
    for (final permission in parseLibraryPermissions(
      xml,
      path,
      placeholders: placeholders,
    )) {
      if (seen.contains(permission.name)) continue;
      final earlier = fromLibraries[permission.name];
      if (earlier == null ||
          (earlier.attributes.containsKey('android:maxSdkVersion') &&
              !permission.attributes.containsKey('android:maxSdkVersion'))) {
        fromLibraries[permission.name] = permission;
      }
    }
  }
  lines.addAll(fromLibraries.values.map((p) => p.render()));
  // An overlay always leaves its provenance, even when it adds nothing.
  if (lines.isEmpty && overlayXml == null) return baseXml;

  final provenance = [
    ?overlayPath,
    if (libraries.isNotEmpty) 'library manifests',
  ];
  final inserted = StringBuffer()
    ..write(
      '\n    <!-- Permissions merged by rules_flutter from '
      '${provenance.join(' and ')} into $basePath. -->',
    );
  for (final line in lines) {
    inserted.write('\n    $line');
  }

  return baseXml.substring(0, insertAt) +
      inserted.toString() +
      baseXml.substring(insertAt);
}

void main(List<String> args) {
  String? basePath;
  String? overlayPath;
  String? outputPath;
  final libraryPaths = <String>[];
  final placeholders = <String>{};
  String? namespace;
  VersionAttribute? versionCode;
  VersionAttribute? versionName;
  var uncompressedNativeLibs = false;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--base' && i + 1 < args.length) {
      basePath = args[++i];
    } else if (args[i] == '--overlay' && i + 1 < args.length) {
      overlayPath = args[++i];
    } else if (args[i] == '--library' && i + 1 < args.length) {
      libraryPaths.add(args[++i]);
    } else if (args[i] == '--placeholder' && i + 1 < args.length) {
      placeholders.add(args[++i]);
    } else if (args[i] == '--namespace' && i + 1 < args.length) {
      namespace = args[++i];
    } else if (args[i] == '--version-code' && i + 1 < args.length) {
      versionCode = (value: args[++i], isDefault: false);
    } else if (args[i] == '--default-version-code' && i + 1 < args.length) {
      versionCode = (value: args[++i], isDefault: true);
    } else if (args[i] == '--version-name' && i + 1 < args.length) {
      versionName = (value: args[++i], isDefault: false);
    } else if (args[i] == '--default-version-name' && i + 1 < args.length) {
      versionName = (value: args[++i], isDefault: true);
    } else if (args[i] == '--uncompressed-native-libs') {
      uncompressedNativeLibs = true;
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[++i];
    }
  }

  if (basePath == null || outputPath == null) {
    stderr.writeln(
      'Usage: dart merge_android_manifests.dart --base <path> '
      '[--overlay <path>] [--library <path>]... [--placeholder <name>]... '
      '[--namespace <package>] '
      '[--version-code <n> | --default-version-code <n>] '
      '[--version-name <s> | --default-version-name <s>] '
      '[--uncompressed-native-libs] --output <path>',
    );
    exit(1);
  }

  final String merged;
  try {
    merged = mergeManifests(
      baseXml: File(basePath).readAsStringSync(),
      basePath: basePath,
      overlayXml: overlayPath == null
          ? null
          : File(overlayPath).readAsStringSync(),
      overlayPath: overlayPath,
      libraries: {
        for (final path in libraryPaths) path: File(path).readAsStringSync(),
      },
      placeholders: placeholders,
      namespace: namespace,
      versionCode: versionCode,
      versionName: versionName,
      uncompressedNativeLibs: uncompressedNativeLibs,
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  File(outputPath).writeAsStringSync(merged);
}
