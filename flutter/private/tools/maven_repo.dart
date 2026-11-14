/// The files of a Maven repository: POMs, `maven-metadata.xml`, and the
/// `.sha1` and `.md5` files beside each, as Gradle's `maven-publish` writes
/// them.
///
/// Shared by the build action that lays out a `flutter_android_aar`
/// repository (`android_maven_repo.dart`) and the program `bazel run` of one
/// starts (`android_aar_install.dart`), which merges `maven-metadata.xml` with
/// what earlier runs wrote. Plain `dart:` imports only, as a build action runs
/// it from the toolchain's Dart.
library;

import 'dart:typed_data';

/// One dependency a POM lists.
class MavenDependency {
  MavenDependency({
    required this.group,
    required this.artifact,
    required this.version,
    required this.scope,
  });

  factory MavenDependency.fromJson(Map<String, Object?> json) =>
      MavenDependency(
        group: json['group']! as String,
        artifact: json['artifact']! as String,
        version: json['version']! as String,
        scope: json['scope']! as String,
      );

  final String group;
  final String artifact;
  final String version;

  /// `compile` (Gradle's `api`) or `runtime` (`implementation`, `runtimeOnly`).
  final String scope;

  String get coordinate => '$group:$artifact:$version';
}

/// Where an artifact's files go in a repository: `<group as path>/<artifact>/<version>`.
String versionDirectory(String group, String artifact, String version) =>
    '${group.replaceAll('.', '/')}/$artifact/$version';

/// Where an artifact's `maven-metadata.xml` goes: `<group as path>/<artifact>`.
String artifactDirectory(String group, String artifact) =>
    '${group.replaceAll('.', '/')}/$artifact';

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// The POM of `group:artifact:version`, of [packaging], listing
/// [dependencies] in order, laid out as Gradle's `maven-publish` writes one.
String pom({
  required String group,
  required String artifact,
  required String version,
  required String packaging,
  required List<MavenDependency> dependencies,
}) {
  final out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<project xmlns="http://maven.apache.org/POM/4.0.0" '
      'xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 '
      'https://maven.apache.org/xsd/maven-4.0.0.xsd" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    )
    ..writeln('  <modelVersion>4.0.0</modelVersion>')
    ..writeln('  <groupId>${_escape(group)}</groupId>')
    ..writeln('  <artifactId>${_escape(artifact)}</artifactId>')
    ..writeln('  <version>${_escape(version)}</version>')
    ..writeln('  <packaging>${_escape(packaging)}</packaging>');
  if (dependencies.isNotEmpty) {
    out.writeln('  <dependencies>');
    for (final d in dependencies) {
      out
        ..writeln('    <dependency>')
        ..writeln('      <groupId>${_escape(d.group)}</groupId>')
        ..writeln('      <artifactId>${_escape(d.artifact)}</artifactId>')
        ..writeln('      <version>${_escape(d.version)}</version>')
        ..writeln('      <scope>${_escape(d.scope)}</scope>')
        ..writeln('    </dependency>');
    }
    out.writeln('  </dependencies>');
  }
  out.writeln('</project>');
  return out.toString();
}

/// What a `maven-metadata.xml` says.
class MavenMetadata {
  MavenMetadata({
    required this.group,
    required this.artifact,
    required this.versions,
    required this.latest,
    required this.release,
    required this.lastUpdated,
  });

  /// Reads one `maven-metadata.xml`, as Gradle writes it.
  ///
  /// Throws [FormatException] when it names no group or artifact.
  factory MavenMetadata.parse(String xml) {
    String? one(String tag) =>
        RegExp('<$tag>([^<]*)</$tag>').firstMatch(xml)?.group(1)?.trim();
    final group = one('groupId');
    final artifact = one('artifactId');
    if (group == null || artifact == null) {
      throw const FormatException(
        'maven-metadata.xml names no groupId or artifactId',
      );
    }
    final versionsBlock =
        RegExp(r'<versions>([\s\S]*?)</versions>').firstMatch(xml)?.group(1) ??
        '';
    return MavenMetadata(
      group: group,
      artifact: artifact,
      versions: [
        for (final m in RegExp(
          r'<version>([^<]*)</version>',
        ).allMatches(versionsBlock))
          m.group(1)!.trim(),
      ],
      latest: one('latest'),
      release: one('release'),
      lastUpdated: one('lastUpdated'),
    );
  }

  final String group;
  final String artifact;
  final List<String> versions;
  final String? latest;
  final String? release;
  final String? lastUpdated;

  /// This metadata with [version] published at [time], as Gradle records a
  /// publication: the version joins the list if it is new, and becomes
  /// `latest` and `release`.
  MavenMetadata publish(String version, DateTime time) => MavenMetadata(
    group: group,
    artifact: artifact,
    versions: [...versions.where((v) => v != version), version],
    latest: version,
    release: version,
    lastUpdated: timestamp(time),
  );

  String toXml() {
    final out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<metadata>')
      ..writeln('  <groupId>${_escape(group)}</groupId>')
      ..writeln('  <artifactId>${_escape(artifact)}</artifactId>')
      ..writeln('  <versioning>');
    if (latest != null) out.writeln('    <latest>${_escape(latest!)}</latest>');
    if (release != null) {
      out.writeln('    <release>${_escape(release!)}</release>');
    }
    out.writeln('    <versions>');
    for (final v in versions) {
      out.writeln('      <version>${_escape(v)}</version>');
    }
    out.writeln('    </versions>');
    if (lastUpdated != null) {
      out.writeln('    <lastUpdated>${_escape(lastUpdated!)}</lastUpdated>');
    }
    out
      ..writeln('  </versioning>')
      ..writeln('</metadata>');
    return out.toString();
  }

  /// Maven's `lastUpdated` form of [time]: `yyyyMMddHHmmss`, in UTC.
  static String timestamp(DateTime time) {
    final t = time.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

String _hex(List<int> words, {required Endian endian}) {
  final bytes = ByteData(words.length * 4);
  for (var i = 0; i < words.length; i++) {
    bytes.setUint32(i * 4, words[i], endian);
  }
  return [
    for (var i = 0; i < bytes.lengthInBytes; i++)
      bytes.getUint8(i).toRadixString(16).padLeft(2, '0'),
  ].join();
}

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;

/// [bytes] padded as SHA-1 and MD5 pad a message, with its bit length in
/// [endian] order.
Uint8List _padded(List<int> bytes, Endian endian) {
  final length = bytes.length;
  final total = ((length + 8) ~/ 64 + 1) * 64;
  final out = Uint8List(total)..setAll(0, bytes);
  out[length] = 0x80;
  final bits = ByteData.sublistView(out, total - 8);
  final bitLength = length * 8;
  if (endian == Endian.big) {
    bits
      ..setUint32(0, bitLength ~/ 0x100000000, Endian.big)
      ..setUint32(4, bitLength & 0xffffffff, Endian.big);
  } else {
    bits
      ..setUint32(0, bitLength & 0xffffffff, Endian.little)
      ..setUint32(4, bitLength ~/ 0x100000000, Endian.little);
  }
  return out;
}

/// The SHA-1 of [bytes], as lowercase hex: what a `.sha1` file holds.
String sha1Hex(List<int> bytes) {
  final message = _padded(bytes, Endian.big);
  final data = ByteData.sublistView(message);
  var h0 = 0x67452301;
  var h1 = 0xefcdab89;
  var h2 = 0x98badcfe;
  var h3 = 0x10325476;
  var h4 = 0xc3d2e1f0;
  final w = Uint32List(80);
  for (var chunk = 0; chunk < message.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = data.getUint32(chunk + i * 4, Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final temp = (_rotl(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  return _hex([h0, h1, h2, h3, h4], endian: Endian.big);
}

const _md5Shifts = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/// MD5's per-round constants: floor(abs(sin(i + 1)) * 2^32).
const _md5K = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, //
  0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, //
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, //
  0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, //
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, //
  0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, //
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa, //
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, //
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, //
  0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, //
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

/// The MD5 of [bytes], as lowercase hex: what a `.md5` file holds.
String md5Hex(List<int> bytes) {
  final message = _padded(bytes, Endian.little);
  final data = ByteData.sublistView(message);
  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;
  final m = Uint32List(16);
  for (var chunk = 0; chunk < message.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      m[i] = data.getUint32(chunk + i * 4, Endian.little);
    }
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d & 0xffffffff) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & 0xffffffff));
        g = (7 * i) % 16;
      }
      f = (f + a + _md5K[i] + m[g]) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl(f, _md5Shifts[i])) & 0xffffffff;
    }
    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }
  return _hex([a0, b0, c0, d0], endian: Endian.little);
}
