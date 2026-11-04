/// What `check_lockfiles.dart` needs to run Bazel in an e2e workspace without
/// the developer's own overrides, and to read the `maven.install` tags of a
/// `MODULE.bazel`.
library;

/// The workspace `.bazelrc` without the line that pulls in the developer's
/// gitignored `.bazelrc.user`.
///
/// That file points `--override_module` at a sibling rules_dart checkout and
/// sets `--lockfile_mode=off`: exactly what a lock check must not see. Bazel
/// has no switch for leaving out one imported file (`--ignore_all_rc_files`
/// also drops the committed `.bazelrc`, whose flags decide what resolves), so
/// the check hands Bazel this copy instead.
String withoutUserRc(String bazelrc) => bazelrc
    .split('\n')
    .where((line) => !_userRcImport.hasMatch(line))
    .join('\n');

final _userRcImport = RegExp(r'^\s*(try-)?import\s+\S*\.bazelrc\.user\s*$');

/// Which of the two lock checks a [LockCheck] is. Each catches stale locks the
/// other passes: `mod deps` the module graph (a stale registry entry), a
/// `--nobuild` build the module extensions (a missing extension result).
enum LockCheck {
  modDeps('bazel mod deps', ['mod', 'deps']),
  analysis('bazel build --nobuild //...', [
    'build',
    '--nobuild',
    '--keep_going',
    '//...',
  ]);

  const LockCheck(this.label, this.args);
  final String label;
  final List<String> args;
}

/// The Bazel arguments to run [args] (a command and its flags) in a
/// workspace whose rc file is [rcFile], if it has one, with the lock file
/// handled as [lockfileMode]: `error` requires it complete and leaves it
/// alone.
///
/// `--noworkspace_rc` stops Bazel reading the workspace's own `.bazelrc`, so
/// that [rcFile], the same file without the `.bazelrc.user` import, is the
/// only one.
List<String> bazelArgs(
  List<String> args, {
  String? rcFile,
  String lockfileMode = 'error',
}) => [
  '--noworkspace_rc',
  if (rcFile != null) '--bazelrc=$rcFile',
  args.first,
  '--lockfile_mode=$lockfileMode',
  '--noshow_progress',
  '--curses=no',
  '--color=no',
  ...args.skip(1),
];

/// The `name` of every `maven.install(...)` in [moduleBazel]; with
/// [pinnedOnly] only those that name a `lock_file`, otherwise only those that
/// do not.
///
/// Without a lock file, rules_jvm_external resolves the artifacts through
/// Coursier at build time: no per-jar checksums, so nothing lands in Bazel's
/// repository cache and every fresh output base downloads every jar again.
/// Only installs on the `maven` extension of `@rules_jvm_external` are looked
/// at, under whatever name `use_extension` binds it to.
List<String> mavenInstallNames(
  String moduleBazel, {
  required bool pinnedOnly,
}) {
  final code = _withoutComments(moduleBazel);
  final extensions = RegExp(
    r'(\w+)\s*=\s*use_extension\(\s*"@rules_jvm_external//:extensions\.bzl"\s*,\s*"maven"',
  ).allMatches(code).map((m) => m.group(1)!).toSet();
  final names = <String>[];
  for (final extension in extensions) {
    for (final call in RegExp('\\b$extension\\.install\\(').allMatches(code)) {
      final body = _balanced(code, call.end);
      final name =
          RegExp(r'\bname\s*=\s*"([^"]*)"').firstMatch(body)?.group(1) ??
          '(unnamed)';
      final blanked = body.replaceAll(RegExp(r'"[^"]*"'), '""');
      final pinned = RegExp(r'\block_file\s*=').hasMatch(blanked);
      if (pinned == pinnedOnly) names.add(name);
    }
  }
  return names;
}

/// The installs in [moduleBazel] that name no `lock_file`.
List<String> unpinnedMavenInstalls(String moduleBazel) =>
    mavenInstallNames(moduleBazel, pinnedOnly: false);

/// The installs in [moduleBazel] that name a `lock_file`.
List<String> pinnedMavenInstalls(String moduleBazel) =>
    mavenInstallNames(moduleBazel, pinnedOnly: true);

/// [source] with every `#` comment dropped; a `#` inside a string stays.
String _withoutComments(String source) => source
    .split('\n')
    .map((line) {
      var inString = false;
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        if (c == '"') inString = !inString;
        if (c == '#' && !inString) return line.substring(0, i);
      }
      return line;
    })
    .join('\n');

/// The text from [start] (just after an opening parenthesis) up to the
/// matching close, skipping parentheses inside strings.
String _balanced(String code, int start) {
  var depth = 1;
  var inString = false;
  for (var i = start; i < code.length; i++) {
    final c = code[i];
    if (c == '"') inString = !inString;
    if (inString) continue;
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return code.substring(start, i);
  }
  return code.substring(start);
}

/// The `@repo//:pin` targets Bazel's output says to run, because a
/// rules_jvm_external lock file no longer matches the artifacts declared in
/// MODULE.bazel ("must be regenerated ... REPIN=1 bazel run @repo//:pin").
///
/// The `build --nobuild` lock check is what finds a stale one: loading the
/// repo compares the lock's input signature with the declared artifacts and
/// fails the build when they differ.
List<String> repinTargets(String bazelOutput) => RegExp(
  r'REPIN=1 bazel run (@\S+//:pin)',
).allMatches(bazelOutput).map((m) => m.group(1)!).toSet().toList()..sort();

/// What rules_jvm_external says is wrong or noisy about the `maven.install`
/// tags of a workspace, one line each, from the output of a fetch of one of its
/// repositories that ran with `REPIN=1` and `--lockfile_mode=off`.
///
/// Both warnings come from evaluating the extension, which a lock file lets
/// Bazel skip, so a locked run never prints them and they showed on every
/// developer's first build. They are:
///
///  * a repository another module also contributes to, whose root install does
///    not say which modules may (`known_contributing_modules`); the warning
///    prints the list to write;
///  * a root install that declares an artifact at a lower version than a
///    dependency's, which wins, so the declaration is not what is used (printed
///    only when repinning).
List<String> mavenWarnings(String bazelOutput) {
  final warnings = <String>[];
  final contributions = RegExp(
    r'The maven repository \x27([^\x27]+)\x27 has contributions from multiple '
    r'bzlmod modules.*?known_contributing_modules = (\[[^\]]*\])',
    dotAll: true,
  );
  final overridden = RegExp(
    r"WARNING: For dependency '([^']+)' the root @(\S+) repo wants version "
    r'(\S+), but got (\S+) from the (\S+) bazel dep',
  );
  // Both kinds, in the order Bazel printed them.
  final all = [
    ...contributions.allMatches(bazelOutput),
    ...overridden.allMatches(bazelOutput),
  ]..sort((a, b) => a.start.compareTo(b.start));
  for (final m in all) {
    if (m.pattern == contributions) {
      warnings.add(
        'maven.install(name = "${m[1]}") needs '
        'known_contributing_modules = ${m[2]}',
      );
    } else {
      warnings.add(
        '${m[1]} is declared at ${m[3]} in @${m[2]}, '
        "but ${m[5]}'s ${m[4]} is used",
      );
    }
  }
  return warnings;
}
