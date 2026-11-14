/// The program behind `bazel run` of a `flutter_android_release` target: signs
/// a Flutter app's Android App Bundle and the APK of the same release build
/// with the user's upload key.
///
/// Signing happens here, at run time, rather than in a build action, so the
/// key and its passwords never enter Bazel's graph or caches. Passwords reach
/// the JDK tools and apksigner only through environment variables set on that
/// one child; no argument list built in this file contains one.
///
/// Environment:
///   RULES_FLUTTER_ANDROID_RELEASE_CONFIG  runfiles path of the JSON file the
///       rule writes: `label`, `package`, `keyProperties` (plain strings), and
///       the runfiles paths `aab`, `apk`, `java`, `jarsigner`, `keytool`,
///       `bundletool`, and `apksigner`, the runfiles paths of apksigner's
///       classpath.
///   BUILD_WORKSPACE_DIRECTORY, BUILD_WORKING_DIRECTORY  set by `bazel run`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

const configEnv = 'RULES_FLUTTER_ANDROID_RELEASE_CONFIG';
const storePasswordEnv = 'RULES_FLUTTER_STORE_PASSWORD';
const keyPasswordEnv = 'RULES_FLUTTER_KEY_PASSWORD';

/// The entry point of the SDK's apksigner, the `main_class` of its
/// `java_binary` in every Android SDK repository.
const apksignerMainClass = 'com.android.apksigner.ApkSignerTool';

/// A failure the user can act on, reported as `error: <message>`.
class ReleaseException implements Exception {
  ReleaseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A command line the tool cannot parse; reported with the usage text.
class UsageException implements Exception {
  UsageException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// key.properties
// ---------------------------------------------------------------------------

bool _isBlank(String c) => c == ' ' || c == '\t' || c == '\f';

/// Parses the subset of the Java `.properties` format that Gradle reads.
Map<String, String> parseProperties(String text) {
  final logical = <String>[];
  final pending = StringBuffer();
  var continuing = false;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    var line = raw;
    if (continuing) {
      var i = 0;
      while (i < line.length && _isBlank(line[i])) {
        i++;
      }
      line = line.substring(i);
    } else {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('!')) {
        continue;
      }
    }
    var slashes = 0;
    for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
      slashes++;
    }
    if (slashes.isOdd) {
      pending.write(line.substring(0, line.length - 1));
      continuing = true;
    } else {
      pending.write(line);
      logical.add(pending.toString());
      pending.clear();
      continuing = false;
    }
  }
  if (continuing) {
    logical.add(pending.toString());
  }

  final result = <String, String>{};
  for (final line in logical) {
    var i = 0;
    while (i < line.length && _isBlank(line[i])) {
      i++;
    }
    final keyStart = i;
    while (i < line.length) {
      final c = line[i];
      if (c == r'\') {
        i += 2;
        continue;
      }
      if (c == '=' || c == ':' || _isBlank(c)) {
        break;
      }
      i++;
    }
    if (i > line.length) {
      i = line.length;
    }
    final key = line.substring(keyStart, i);
    while (i < line.length && _isBlank(line[i])) {
      i++;
    }
    if (i < line.length && (line[i] == '=' || line[i] == ':')) {
      i++;
    }
    while (i < line.length && _isBlank(line[i])) {
      i++;
    }
    result[_unescape(key)] = _unescape(line.substring(i));
  }
  return result;
}

String _unescape(String s) {
  if (!s.contains(r'\')) {
    return s;
  }
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c != r'\') {
      out.write(c);
      continue;
    }
    i++;
    if (i >= s.length) {
      break;
    }
    switch (s[i]) {
      case 't':
        out.write('\t');
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'u':
        final hex = i + 5 <= s.length ? s.substring(i + 1, i + 5) : '';
        final code = RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)
            ? int.parse(hex, radix: 16)
            : null;
        if (code == null) {
          throw ReleaseException(r'key.properties has a malformed \u escape');
        }
        out.writeCharCode(code);
        i += 4;
      default:
        out.write(s[i]);
    }
  }
  return out.toString();
}

/// What `key.properties` says.
class SigningConfig {
  SigningConfig({
    required this.storePassword,
    required this.keyPassword,
    required this.keyAlias,
    required this.storeFile,
  });

  /// Validates the four keys and resolves `storeFile`: absolute stays, a
  /// relative one is relative to [androidAppDir] (Gradle's `app` project).
  factory SigningConfig.from(
    Map<String, String> properties, {
    required String keyPropertiesPath,
    String? androidAppDir,
  }) {
    String need(String key) {
      final value = properties[key];
      if (value == null || value.isEmpty) {
        throw ReleaseException(
          '$keyPropertiesPath has no `$key`; it needs storePassword, '
          'keyPassword, keyAlias and storeFile',
        );
      }
      return value;
    }

    final storePassword = need('storePassword');
    final keyPassword = need('keyPassword');
    final keyAlias = need('keyAlias');
    var storeFile = need('storeFile');
    if (!_isAbsolute(storeFile)) {
      if (androidAppDir == null) {
        throw ReleaseException(
          '`storeFile` in $keyPropertiesPath is relative ($storeFile), and '
          'outside `bazel run` there is nothing to resolve it against; '
          'make it absolute',
        );
      }
      storeFile = '$androidAppDir/$storeFile';
    }
    return SigningConfig(
      storePassword: storePassword,
      keyPassword: keyPassword,
      keyAlias: keyAlias,
      storeFile: storeFile,
    );
  }

  final String storePassword;
  final String keyPassword;
  final String keyAlias;
  final String storeFile;
}

bool _isAbsolute(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

// ---------------------------------------------------------------------------
// Argument builders. None takes a password.
// ---------------------------------------------------------------------------

const _keytoolEnglish = ['-J-Duser.language=en', '-J-Duser.country=US'];

List<String> keytoolListArgs({
  required String keystore,
  required String alias,
}) => [
  ..._keytoolEnglish,
  '-list',
  '-v',
  '-keystore',
  keystore,
  '-alias',
  alias,
  '-storepass:env',
  storePasswordEnv,
];

List<String> keytoolGenkeyArgs({
  required String keystore,
  required String alias,
  required String dname,
}) => [
  ..._keytoolEnglish,
  '-genkeypair',
  '-keystore',
  keystore,
  '-storetype',
  'PKCS12',
  '-alias',
  alias,
  '-keyalg',
  'RSA',
  '-keysize',
  '2048',
  '-validity',
  '10000',
  '-dname',
  dname,
  '-storepass:env',
  storePasswordEnv,
  '-keypass:env',
  keyPasswordEnv,
];

List<String> jarsignerSignArgs({
  required String keystore,
  required String alias,
  required String sigalg,
  required String unsigned,
  required String signedOut,
}) => [
  '-J-Duser.language=en',
  '-keystore',
  keystore,
  '-storepass:env',
  storePasswordEnv,
  '-keypass:env',
  keyPasswordEnv,
  '-digestalg',
  'SHA-256',
  '-sigalg',
  sigalg,
  '-signedjar',
  signedOut,
  unsigned,
  alias,
];

/// Not `-strict`: that exits 4 for any self-signed certificate, which every
/// upload key is.
List<String> jarsignerVerifyArgs(String signed) => [
  '-J-Duser.language=en',
  '-verify',
  signed,
];

List<String> printcertArgs(String signed) => [
  ..._keytoolEnglish,
  '-printcert',
  '-jarfile',
  signed,
];

List<String> bundletoolValidateArgs({
  required String bundletool,
  required String bundle,
}) => ['-jar', bundletool, 'validate', '--bundle=$bundle'];

/// Signs the APK [unsigned] with the upload key, writing [signedOut], with
/// the SDK's apksigner, whose classpath is [apksigner].
///
/// The build stored the APK's native libraries uncompressed and zipaligned
/// them to 16 KB, as AGP packages `flutter build apk`, which a device with
/// 16 KB pages needs to map them; apksigner keeps that alignment, and
/// replaces the debug signature the build gave the APK.
List<String> apksignerSignArgs({
  required List<String> apksigner,
  required String keystore,
  required String alias,
  required String unsigned,
  required String signedOut,
}) => [
  '-cp',
  apksigner.join(Platform.isWindows ? ';' : ':'),
  apksignerMainClass,
  'sign',
  '--ks',
  keystore,
  '--ks-key-alias',
  alias,
  '--ks-pass',
  'env:$storePasswordEnv',
  '--key-pass',
  'env:$keyPasswordEnv',
  '--alignment-preserved',
  'true',
  '--out',
  signedOut,
  unsigned,
];

// ---------------------------------------------------------------------------
// keytool output
// ---------------------------------------------------------------------------

/// The signature algorithm for the key in a `keytool -list -v` listing.
String sigalgFor(String keytoolListing) {
  final match = RegExp(
    r'Subject Public Key Algorithm:\s*(.*)',
  ).firstMatch(keytoolListing);
  if (match == null) {
    throw ReleaseException(
      'keytool did not report the key algorithm of the signing key',
    );
  }
  final description = match.group(1)!.trim();
  final kind = RegExp(r'\b(RSA|EC|DSA)\b[^\n]* key\b')
      .firstMatch(description)
      ?.group(1);
  return switch (kind) {
    'RSA' => 'SHA256withRSA',
    'EC' => 'SHA256withECDSA',
    'DSA' => 'SHA256withDSA',
    _ => throw ReleaseException(
      'the signing key is "$description"; only RSA, EC and DSA keys can '
      'sign an app bundle',
    ),
  };
}

/// Every `SHA256:` certificate fingerprint in keytool output, in order.
List<String> fingerprintsIn(String keytoolOutput) => [
  for (final m in RegExp(
    r'SHA256:\s*([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})+)',
  ).allMatches(keytoolOutput))
    m.group(1)!.toUpperCase(),
];

/// The first certificate SHA-256 fingerprint in keytool output.
String fingerprintFrom(String keytoolOutput) {
  final all = fingerprintsIn(keytoolOutput);
  if (all.isEmpty) {
    throw ReleaseException('keytool printed no SHA256 fingerprint');
  }
  return all.first;
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

/// The rule's JSON, with every runfiles path resolved.
class ToolConfig {
  ToolConfig({
    required this.label,
    required this.package,
    required this.keyProperties,
    required this.aab,
    required this.apk,
    required this.java,
    required this.jarsigner,
    required this.keytool,
    required this.bundletool,
    required this.apksigner,
  });

  factory ToolConfig.load(Runfiles runfiles, String configRunfilesPath) {
    final file = File(runfiles.rlocation(configRunfilesPath));
    if (!file.existsSync()) {
      throw ReleaseException('the release config ${file.path} is missing');
    }
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    String plain(String key) {
      final value = json[key];
      if (value is! String) {
        throw ReleaseException('the release config has no `$key`');
      }
      return value;
    }

    String path(String key) => runfiles.rlocation(plain(key));
    List<String> paths(String key) {
      final value = json[key];
      if (value is! List || value.isEmpty || value.any((p) => p is! String)) {
        throw ReleaseException('the release config has no `$key` paths');
      }
      return [for (final p in value) runfiles.rlocation(p as String)];
    }

    return ToolConfig(
      label: plain('label'),
      package: plain('package'),
      keyProperties: plain('keyProperties'),
      aab: path('aab'),
      apk: path('apk'),
      java: path('java'),
      jarsigner: path('jarsigner'),
      keytool: path('keytool'),
      bundletool: path('bundletool'),
      apksigner: paths('apksigner'),
    );
  }

  final String label;
  final String package;
  final String keyProperties;
  final String aab;

  /// The release build's APK, signed with the debug key.
  final String apk;
  final String java;
  final String jarsigner;
  final String keytool;
  final String bundletool;

  /// The classpath of the Android SDK's apksigner.
  final List<String> apksigner;
}

String _join(Iterable<String> parts) =>
    parts.where((p) => p.isNotEmpty).join('/');

Future<String> _run(
  String executable,
  List<String> args, {
  required String what,
  SigningConfig? passwords,
  String? workingDirectory,
}) async {
  final ProcessResult result;
  try {
    result = await Process.run(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: {
        if (passwords != null) storePasswordEnv: passwords.storePassword,
        if (passwords != null) keyPasswordEnv: passwords.keyPassword,
      },
    );
  } on ProcessException catch (e) {
    throw ReleaseException('$what could not start: ${e.message}');
  }
  final output = '${result.stdout}${result.stderr}';
  if (result.exitCode != 0) {
    throw ReleaseException(
      '$what failed (exit ${result.exitCode}):\n${output.trimRight()}',
    );
  }
  return output;
}

class _Context {
  _Context(this.config, this.args);

  final ToolConfig config;
  final Map<String, String> args;

  final String? workspace = _env('BUILD_WORKSPACE_DIRECTORY');
  final String? workingDirectory = _env('BUILD_WORKING_DIRECTORY');

  static String? _env(String name) {
    final value = Platform.environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  String _fromWorkingDirectory(String path) {
    if (_isAbsolute(path)) {
      return path;
    }
    return '${workingDirectory ?? Directory.current.path}/$path';
  }

  String get packageDir => _join([workspace!, config.package]);

  String get keyPropertiesPath {
    final flag = args['key-properties'];
    if (flag != null) {
      return _fromWorkingDirectory(flag);
    }
    if (workspace == null) {
      throw ReleaseException(
        'pass --key-properties=<path>: outside `bazel run` there is no '
        'workspace to find ${config.keyProperties} in',
      );
    }
    return _join([packageDir, config.keyProperties]);
  }

  SigningConfig readSigning({required bool forCreate}) {
    final path = keyPropertiesPath;
    final file = File(path);
    if (!file.existsSync()) {
      throw ReleaseException(
        forCreate
            ? '$path does not exist; create it with storePassword, '
                  'keyPassword, keyAlias and storeFile, then run '
                  '`bazel run ${config.label} -- create-key` again'
            : '$path does not exist; create a signing key and that file with '
                  '`bazel run ${config.label} -- create-key`',
      );
    }
    return SigningConfig.from(
      parseProperties(file.readAsStringSync()),
      keyPropertiesPath: path,
      androidAppDir: workspace == null ? null : '$packageDir/android/app',
    );
  }
}

Future<void> _sign(_Context ctx) async {
  final config = ctx.config;
  final keyPropertiesPath = ctx.keyPropertiesPath;
  final signing = ctx.readSigning(forCreate: false);
  if (!File(signing.storeFile).existsSync()) {
    throw ReleaseException(
      '`storeFile` in $keyPropertiesPath names ${signing.storeFile}, which '
      'does not exist; `bazel run ${config.label} -- create-key` makes it',
    );
  }

  final outputDir = ctx.args['output-dir'];
  final String aabOut;
  final String apkOut;
  if (outputDir != null) {
    final dir = ctx._fromWorkingDirectory(outputDir);
    aabOut = '$dir/app-release.aab';
    apkOut = '$dir/app-release.apk';
  } else {
    if (ctx.workspace == null) {
      throw ReleaseException(
        'pass --output-dir=<dir>: outside `bazel run` there is no workspace '
        'to write build/app/outputs into',
      );
    }
    aabOut =
        '${ctx.packageDir}/build/app/outputs/bundle/release/app-release.aab';
    apkOut = '${ctx.packageDir}/build/app/outputs/flutter-apk/app-release.apk';
  }

  final tmp = await Directory.systemTemp.createTemp('android_release_');
  try {
    // 2. The key's fingerprint and algorithm.
    final String listing;
    try {
      listing = await _run(
        config.keytool,
        keytoolListArgs(keystore: signing.storeFile, alias: signing.keyAlias),
        what: 'keytool -list',
        passwords: signing,
      );
    } on ReleaseException catch (e) {
      throw ReleaseException(
        '${e.message}\n(signing configuration: $keyPropertiesPath, '
        'alias `${signing.keyAlias}`)',
      );
    }
    final fingerprint = fingerprintFrom(listing);
    final sigalg = sigalgFor(listing);

    // 3. Sign the bundle.
    final signedAab = '${tmp.path}/app-release.aab';
    await _run(
      config.jarsigner,
      jarsignerSignArgs(
        keystore: signing.storeFile,
        alias: signing.keyAlias,
        sigalg: sigalg,
        unsigned: config.aab,
        signedOut: signedAab,
      ),
      what: 'jarsigner',
      passwords: signing,
    );

    // 4. Check it.
    final verified = await _run(
      config.jarsigner,
      jarsignerVerifyArgs(signedAab),
      what: 'jarsigner -verify',
    );
    if (!verified.contains('jar verified.')) {
      throw ReleaseException(
        'jarsigner -verify did not report "jar verified.":\n$verified',
      );
    }
    final certs = fingerprintsIn(
      await _run(
        config.keytool,
        printcertArgs(signedAab),
        what: 'keytool -printcert',
      ),
    );
    if (certs.length != 1 || certs.single != fingerprint) {
      throw ReleaseException(
        'the signed bundle carries ${certs.length} signer fingerprint(s) '
        '${certs.join(', ')}, expected only $fingerprint',
      );
    }
    await _run(
      config.java,
      bundletoolValidateArgs(bundletool: config.bundletool, bundle: signedAab),
      what: 'bundletool validate',
    );

    // 5. The APK.
    await _run(
      config.java,
      apksignerSignArgs(
        apksigner: config.apksigner,
        keystore: signing.storeFile,
        alias: signing.keyAlias,
        unsigned: config.apk,
        signedOut: '${tmp.path}/app-release.apk',
      ),
      what: 'apksigner sign',
      passwords: signing,
    );

    // 6. Write both, only now that everything succeeded.
    _writeAtomically('${tmp.path}/app-release.aab', aabOut);
    _writeAtomically('${tmp.path}/app-release.apk', apkOut);

    // 7. Report.
    stdout
      ..writeln(aabOut)
      ..writeln(apkOut)
      ..writeln(
        'Signed with key "${signing.keyAlias}" (certificate SHA-256 '
        '$fingerprint) from ${signing.storeFile}',
      )
      ..writeln(
        "Play Console > Test and release > App integrity lists the upload "
        "certificate's SHA-256; it must match.",
      );
  } finally {
    // 8.
    await tmp.delete(recursive: true);
  }
}

void _writeAtomically(String source, String destination) {
  final parent = File(destination).parent;
  parent.createSync(recursive: true);
  final partial = '$destination.tmp';
  File(source).copySync(partial);
  File(partial).renameSync(destination);
}

Future<void> _createKey(_Context ctx) async {
  final signing = ctx.readSigning(forCreate: true);
  final path = ctx.keyPropertiesPath;
  if (File(signing.storeFile).existsSync() ||
      Directory(signing.storeFile).existsSync()) {
    throw ReleaseException(
      '${signing.storeFile} already exists, so nothing was created. Delete '
      'it yourself if you mean to replace it: a lost upload key is reset '
      'through Play Console, a lost app signing key cannot be.',
    );
  }
  if (signing.storePassword != signing.keyPassword) {
    throw ReleaseException(
      'storePassword and keyPassword in $path differ; a PKCS12 keystore has '
      'one password, so make them equal',
    );
  }
  if (signing.storePassword.length < 6) {
    throw ReleaseException(
      'storePassword in $path is shorter than 6 characters, the least '
      'keytool accepts',
    );
  }
  final parent = File(signing.storeFile).parent;
  if (!parent.existsSync()) {
    throw ReleaseException(
      'the directory ${parent.path} for storeFile does not exist; create it '
      'first',
    );
  }
  final config = ctx.config;
  await _run(
    config.keytool,
    keytoolGenkeyArgs(
      keystore: signing.storeFile,
      alias: signing.keyAlias,
      dname: ctx.args['dname'] ?? 'CN=Upload Key',
    ),
    what: 'keytool -genkeypair',
    passwords: signing,
  );
  final fingerprint = fingerprintFrom(
    await _run(
      config.keytool,
      keytoolListArgs(keystore: signing.storeFile, alias: signing.keyAlias),
      what: 'keytool -list',
      passwords: signing,
    ),
  );
  stdout
    ..writeln('Created ${signing.storeFile} with key "${signing.keyAlias}"')
    ..writeln('Certificate SHA-256: $fingerprint')
    ..writeln(
      'Back up the keystore and its password now, and never commit either. '
      'Then `bazel run ${config.label}` signs a release.',
    );
}

const _usage =
    'Usage: bazel run <flutter_android_release target> -- [command] [flags]\n'
    '  sign (default)\n'
    '      --key-properties=<path>  default: <package>/android/key.properties\n'
    '      --output-dir=<dir>       default: <package>/build/app/outputs/...\n'
    '  create-key\n'
    '      --key-properties=<path>\n'
    '      --dname=<X.500 name>     default: "CN=Upload Key"';

/// Parses `--name=value` flags; only [allowed] names are accepted.
Map<String, String> parseFlags(List<String> args, Set<String> allowed) {
  final flags = <String, String>{};
  for (final arg in args) {
    final match = RegExp(r'^--([a-z-]+)=(.*)$').firstMatch(arg);
    if (match == null || !allowed.contains(match.group(1))) {
      throw UsageException('unknown argument: $arg');
    }
    flags[match.group(1)!] = match.group(2)!;
  }
  return flags;
}

Future<void> main(List<String> args) async {
  try {
    final command = args.isEmpty || args.first.startsWith('--')
        ? 'sign'
        : args.first;
    final rest =
        command == 'sign' && args.isNotEmpty && args.first.startsWith('--')
        ? args
        : args.skip(1).toList();
    final Map<String, String> flags;
    switch (command) {
      case 'sign':
        flags = parseFlags(rest, {'key-properties', 'output-dir'});
      case 'create-key':
        flags = parseFlags(rest, {'key-properties', 'dname'});
      default:
        throw UsageException('unknown command: $command');
    }

    final configPath = Platform.environment[configEnv];
    if (configPath == null || configPath.isEmpty) {
      throw ReleaseException(
        'run this through `bazel run` of a flutter_android_release target',
      );
    }
    final ctx = _Context(ToolConfig.load(Runfiles.create(), configPath), flags);
    if (command == 'sign') {
      await _sign(ctx);
    } else {
      await _createKey(ctx);
    }
  } on UsageException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln(_usage);
    exit(64);
  } on ReleaseException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
