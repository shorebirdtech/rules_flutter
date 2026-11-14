/// Finding the build host in a built artifact.
///
/// An output that is a function of its declared inputs holds nothing about the
/// machine or sandbox that built it. A string naming the build's execroot, its
/// sandbox slot or the builder's home directory is a sign that the bytes are
/// not: the same inputs built elsewhere, or by the next sandbox number, give
/// different bytes, and the output misses a shared cache.
library;

import 'dart:convert';
import 'dart:io';

/// One kind of host-specific string and how to recognise it.
class HostMarker {
  /// A marker called [label] that matches [pattern] (a [String] is matched
  /// literally, a [RegExp] as written).
  const HostMarker(this.label, this.pattern);

  /// What a finding calls this marker.
  final String label;

  /// What to look for.
  final Pattern pattern;
}

/// The strings that tie an artifact to the machine and sandbox that built it.
class HostMarkers {
  /// The markers [markers].
  const HostMarkers(this.markers);

  /// The markers for a test that runs where the artifacts it inspects were
  /// built.
  ///
  /// [anchorPaths] are paths in the build's output tree, such as the test's
  /// runfiles directory: the output base is read from the first that lies
  /// under an execroot (a symlink in the runfiles can lead out of it, to a
  /// cache). [env] is the environment the home directory and user name come
  /// from.
  ///
  /// The patterns are shaped like paths on purpose. The word "sandbox" alone
  /// is not a marker: the Dart SDK has an `iframe.sandbox` and
  /// `file:///home/myself/...` in its doc strings, and both reach every kernel.
  factory HostMarkers.forBuildHost(
    Iterable<String> anchorPaths, {
    Map<String, String>? env,
  }) {
    env ??= Platform.environment;
    final markers = <HostMarker>[
      const HostMarker('execroot', '/execroot/'),
      HostMarker('sandbox slot', RegExp(r'-sandbox/\d+/')),
      HostMarker(
        'Bazel output base',
        RegExp(r'/_bazel_[A-Za-z0-9._-]+/[0-9a-f]{32}'),
      ),
    ];
    final outputBase = anchorPaths
        .map(outputBaseOf)
        .firstWhere((base) => base != null, orElse: () => null);
    if (outputBase != null) {
      markers.add(HostMarker('output base $outputBase', outputBase));
    }
    final home = env['HOME'];
    if (home != null && home.length > 4) {
      markers.add(HostMarker('home directory $home', '$home/'));
    }
    final user = env['USER'];
    if (user != null && user.length > 2) {
      markers.add(HostMarker('user name "$user"', '/$user/'));
    }
    return HostMarkers(markers);
  }

  /// The markers, in the order findings list them.
  final List<HostMarker> markers;

  /// Where [bytes] hold a marker. Reports each marker once, with how many times
  /// it occurs and the text around the first.
  List<HostLeak> inBytes(List<int> bytes, {required String source}) {
    // Latin-1 maps each byte to one code unit, so a path in a binary file
    // (UTF-8 in a kernel, ASCII in a wasm data segment) keeps its text and
    // an offset in the string is an offset in the file.
    final text = latin1.decode(bytes);
    return [
      for (final marker in markers)
        if (marker.pattern.allMatches(text).toList() case final hits
            when hits.isNotEmpty)
          HostLeak(
            source: source,
            label: marker.label,
            count: hits.length,
            context: _around(text, hits.first.start, hits.first.end),
          ),
    ];
  }

  /// Where the file at [path], or every file under it if it is a directory,
  /// holds a marker.
  List<HostLeak> inTree(String path) {
    final leaks = <HostLeak>[];
    if (FileSystemEntity.isDirectorySync(path)) {
      for (final entity in Directory(
        path,
      ).listSync(recursive: true, followLinks: true)) {
        if (entity is File) {
          leaks.addAll(
            inBytes(
              entity.readAsBytesSync(),
              source: entity.path.substring(path.length + 1),
            ),
          );
        }
      }
    } else {
      leaks.addAll(
        inBytes(
          File(path).readAsBytesSync(),
          source: path.split(RegExp(r'[\\/]')).last,
        ),
      );
    }
    return leaks;
  }
}

/// A marker found in a file.
class HostLeak {
  /// [count] occurrences of the [label] marker in [source], the first with
  /// [context] around it.
  const HostLeak({
    required this.source,
    required this.label,
    required this.count,
    required this.context,
  });

  /// The file, relative to what was scanned.
  final String source;

  /// The marker's label.
  final String label;

  /// How many times the marker occurs in the file.
  final int count;

  /// The text around the first occurrence, with unprintable bytes shown as `.`.
  final String context;

  @override
  String toString() => '$source: $count x $label, e.g. "$context"';
}

/// The Bazel output base [path] lies under, or null if it is not under an
/// execroot.
///
/// The execroot of a sandboxed action is `<output base>/sandbox/<kind>/<slot>/
/// execroot`, and of an unsandboxed one `<output base>/execroot`; both give
/// `<output base>`.
String? outputBaseOf(String path) {
  final resolved = File(path).existsSync() || Directory(path).existsSync()
      ? FileSystemEntity.isDirectorySync(path)
            ? Directory(path).resolveSymbolicLinksSync()
            : File(path).resolveSymbolicLinksSync()
      : path;
  final match = RegExp(
    r'^(.+?)/(?:sandbox/[^/]+/\d+/)?execroot/',
  ).firstMatch(resolved);
  return match?.group(1);
}

String _around(String text, int start, int end) {
  const margin = 40;
  final from = start - margin < 0 ? 0 : start - margin;
  final to = end + margin > text.length ? text.length : end + margin;
  return text.substring(from, to).replaceAll(RegExp(r'[^\x20-\x7e]'), '.');
}

/// The OS value RFC 1952 gives to "unknown", the only one that does not name
/// a host.
const gzipOsUnknown = 255;

/// What in the header of gzip stream [bytes] depends on who wrote it, as
/// sentences; empty if nothing does.
///
/// A gzip header carries a modification time and the OS of the compressor,
/// and zlib fills the latter from the platform it was built for (3 for Unix,
/// 19 for Darwin, 10 for Windows). The same text compressed on two hosts then
/// differs in one byte.
List<String> gzipHeaderHostDependence(List<int> bytes) {
  if (bytes.length < 10 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
    return ['not a gzip stream'];
  }
  final mtime = bytes[4] | bytes[5] << 8 | bytes[6] << 16 | bytes[7] << 24;
  return [
    if (mtime != 0) 'modification time is $mtime, not 0',
    if (bytes[9] != gzipOsUnknown)
      'OS byte is ${bytes[9]}, not $gzipOsUnknown (unknown)',
  ];
}
