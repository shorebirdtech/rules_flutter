/// What the updater knows about a Debian archive: how a `Packages` index reads,
/// which packages the Linux integration-test runtime starts from, and how their
/// dependency closure is worked out and written as pins.
///
/// Pure, so that the closure and what is written can be checked without a
/// network.
library;

/// The Debian release the runtime is taken from.
const suite = 'trixie';

/// The architectures pinned, by Debian's name for each.
const architectures = ['amd64', 'arm64'];

/// The packages the runtime starts from, with what each is there for. Their
/// dependencies are added by [resolveClosure].
const rootPackages = {
  // The display the app's window is on: an X server of the test's own.
  'xvfb': 'the X server a desktop test draws on',
  // A GTK app and the software OpenGL its Flutter view draws with: there is no
  // GPU to draw on in an X server in memory.
  'libgtk-3-0t64': 'the GTK the Linux runner is linked against',
  'libgl1-mesa-dri': 'Mesa\'s software rasteriser (llvmpipe)',
  'libglx-mesa0': 'Mesa\'s GLX, which GDK draws a GL area with on X11',
  'libegl-mesa0': 'Mesa\'s EGL',
  'libegl1': 'the EGL dispatcher',
  'libgl1': 'the OpenGL dispatcher',
  'libgles2': 'the OpenGL ES dispatcher',
  'fonts-dejavu-core': 'the fonts text is drawn with, never the host\'s',
  // What the headless shell links, beyond what GTK brings: its `NEEDED`
  // entries, which the build checks resolve.
  'libnss3': 'Chrome\'s TLS and certificate store',
  'libasound2t64': 'Chrome links ALSA',
  'libgbm1': 'Chrome links GBM',
  'libxkbcommon0': 'Chrome links xkbcommon',
  'libudev1': 'Chrome links libudev',
};

/// Packages never taken into the runtime, with why.
///
/// The C and C++ runtimes are the host's: a program is started by the host's
/// dynamic loader, which must be the one of the C library it loads, and a C++
/// program built by the host's compiler needs a C++ library at least as new as
/// that compiler's. The build checks that no pinned file asks more of them than
/// [hostRuntimeFloor] says.
const excludedPackages = {
  'libc6': 'the host\'s C library',
  'libgcc-s1': 'the host\'s C++ runtime',
  'libstdc++6': 'the host\'s C++ runtime',
  // GLib keeps a test's settings in memory without it. Through it come the
  // D-Bus daemons, PAM and systemd, which a test never starts.
  'dconf-gsettings-backend': 'a settings store that needs a session daemon',
};

/// The newest version of each host library a pinned file may ask for: Ubuntu
/// 24.04's, the oldest host supported. The build fails on a file that asks for
/// more.
const hostRuntimeFloor = {
  'GLIBC': '2.39',
  'GLIBCXX': '3.4.33',
  'CXXABI': '1.3.15',
  'GCC': '14.0.0',
};

/// One package of a `Packages` index.
class DebianPackage {
  /// A package as its stanza reads.
  const DebianPackage({
    required this.name,
    required this.version,
    required this.filename,
    required this.sha256,
    required this.depends,
    required this.provides,
    required this.essential,
  });

  /// `Package:`.
  final String name;

  /// `Version:`.
  final String version;

  /// `Filename:`, the path of the `.deb` under the archive's root.
  final String filename;

  /// `SHA256:` of the `.deb`.
  final String sha256;

  /// `Pre-Depends:` and `Depends:`: each a list of alternatives, by name.
  final List<List<String>> depends;

  /// `Provides:`, by name.
  final List<String> provides;

  /// `Essential: yes`: part of every Debian system, so never a library a
  /// program loads.
  final bool essential;
}

/// The packages of the `Packages` index [text], by name.
Map<String, DebianPackage> parsePackagesIndex(String text) {
  final packages = <String, DebianPackage>{};
  for (final stanza in text.split(RegExp(r'\n\s*\n'))) {
    final fields = _fields(stanza);
    final name = fields['Package'];
    if (name == null) continue;
    String require(String key) {
      final value = fields[key];
      if (value == null || value.isEmpty) {
        throw FormatException('package $name has no $key');
      }
      return value;
    }

    packages[name] = DebianPackage(
      name: name,
      version: require('Version'),
      filename: require('Filename'),
      sha256: require('SHA256'),
      depends: [
        ..._relations(fields['Pre-Depends']),
        ..._relations(fields['Depends']),
      ],
      provides: [
        for (final alternatives in _relations(fields['Provides']))
          ...alternatives,
      ],
      essential: fields['Essential'] == 'yes',
    );
  }
  return packages;
}

Map<String, String> _fields(String stanza) {
  final fields = <String, String>{};
  String? key;
  for (final line in stanza.split('\n')) {
    if (line.isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (key != null) fields[key] = '${fields[key]}\n${line.trim()}';
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    key = line.substring(0, colon);
    fields[key] = line.substring(colon + 1).trim();
  }
  return fields;
}

/// A relation field (`a (>= 1) | b:any, c`) as alternatives of names: the
/// version constraints are dropped, since an index holds one version of each.
List<List<String>> _relations(String? field) {
  if (field == null || field.trim().isEmpty) return const [];
  return [
    for (final relation in field.split(','))
      [
        for (final alternative in relation.split('|'))
          alternative.trim().split(RegExp(r'[\s(\[]')).first.split(':').first,
      ],
  ];
}

/// The packages [roots] need, from [index]: each root and what it depends on,
/// transitively, by name.
///
/// Of alternatives, the first the index has (by name, then by what a package
/// provides) is taken. A package in [excluded] or marked essential is not
/// taken, nor are its dependencies through it. A root or a dependency the index
/// has nothing for throws, naming it: a closure with a hole would fail only
/// when a test loads the library.
List<DebianPackage> resolveClosure(
  Map<String, DebianPackage> index, {
  required Iterable<String> roots,
  required Set<String> excluded,
}) {
  final providers = <String, List<DebianPackage>>{};
  for (final package in index.values) {
    for (final name in package.provides) {
      (providers[name] ??= []).add(package);
    }
  }
  DebianPackage? find(String name) {
    final real = index[name];
    if (real != null) return real;
    final provided = providers[name];
    if (provided == null || provided.isEmpty) return null;
    // Deterministic whichever order the index lists them in.
    return (provided.toList()..sort((a, b) => a.name.compareTo(b.name))).first;
  }

  final taken = <String, DebianPackage>{};
  final pending = <(DebianPackage, String)>[];
  for (final root in roots) {
    final package = index[root];
    if (package == null) {
      throw StateError('the index has no package $root, a root of the runtime');
    }
    pending.add((package, 'a root'));
  }
  while (pending.isNotEmpty) {
    final (package, _) = pending.removeLast();
    if (taken.containsKey(package.name)) continue;
    if (excluded.contains(package.name) || package.essential) continue;
    taken[package.name] = package;
    for (final alternatives in package.depends) {
      if (alternatives.any(excluded.contains)) continue;
      DebianPackage? chosen;
      for (final name in alternatives) {
        chosen = find(name);
        if (chosen != null) break;
      }
      if (chosen == null) {
        throw StateError(
          '${package.name} depends on ${alternatives.join(' | ')}, which the '
          'index has no package for',
        );
      }
      pending.add((chosen, package.name));
    }
  }
  return taken.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// The pins file: the closure of each architecture at [snapshot], a
/// snapshot.debian.org timestamp.
String renderPins(String snapshot, Map<String, List<DebianPackage>> closures) {
  final out = StringBuffer()
    ..writeln(
      '"""The Debian packages the Linux integration-test runtime is made of."""',
    )
    ..writeln()
    ..writeln(
      '# Generated by `bazel run //tools/update_linux_runtime`; do not edit.',
    )
    ..writeln('#')
    ..writeln(
      '# Each architecture\'s closure of the packages that tool starts from, as',
    )
    ..writeln(
      '# Debian $suite has them in snapshot.debian.org\'s archive at `snapshot`:',
    )
    ..writeln(
      '# (package, version, path under the archive, sha256 of the .deb).',
    )
    ..writeln()
    ..writeln('LINUX_RUNTIME = struct(')
    ..writeln('    suite = "$suite",')
    ..writeln('    snapshot = "$snapshot",')
    ..writeln('    floor = {');
  for (final MapEntry(:key, :value) in hostRuntimeFloor.entries) {
    out.writeln('        "$key": "$value",');
  }
  out
    ..writeln('    },')
    ..writeln('    packages = {');
  for (final arch in closures.keys.toList()..sort()) {
    out.writeln('        "$arch": [');
    for (final package in closures[arch]!) {
      out.writeln(
        '            ("${package.name}", "${package.version}", '
        '"${package.filename}", "${package.sha256}"),',
      );
    }
    out.writeln('        ],');
  }
  out
    ..writeln('    },')
    ..writeln(')');
  return out.toString();
}
