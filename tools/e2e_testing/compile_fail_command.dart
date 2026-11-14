/// Records the command line of an action, param files included, for
/// `compile_fail_test` to run it again at test time.
///
/// `compile_fail_test` runs this with the action's own `Args`, so Bazel hands
/// it the command line exactly as it hands it to the action: the same
/// arguments, the same param files, the same output paths. Its own arguments
/// come first: the record to write and the action's command line as
/// `Action.argv` gives it, expanded, which the record must match once its
/// param files are read back, or the record is not the action's command.
///
/// Usage: compile_fail_command <record> <expected argv JSON> <command...>
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final record = args[0];
  final expected = (json.decode(File(args[1]).readAsStringSync()) as List)
      .cast<String>();
  final argv = args.sublist(2);

  // Bazel names an action's param files after its first output.
  final paramFile = RegExp('^@(${RegExp.escape(record)}-[0-9]+\\.params)\$');
  final params = <String, String>{};
  final expanded = <String>[];
  final unquoted = <String>[];
  for (final arg in argv) {
    final match = paramFile.firstMatch(arg);
    if (match == null) {
      expanded.add(arg);
      unquoted.add(arg);
      continue;
    }
    final content = File(match[1]!).readAsStringSync();
    params[match[1]!] = content;
    final lines = const LineSplitter().convert(content);
    expanded.addAll(lines);
    unquoted.addAll(lines.map(_unquote));
  }

  // A `multiline` param file holds an argument a line, a `shell` one each
  // argument quoted as a shell would read it.
  if (!_equal(expanded, expected) && !_equal(unquoted, expected)) {
    stderr.writeln(
      'compile_fail_command: the command Bazel gave is not the '
      "action's.\nGiven:    ${expanded.join(' ')}\n"
      "Expected: ${expected.join(' ')}",
    );
    await stderr.flush();
    exit(1);
  }
  File(record).writeAsStringSync(
    json.encode({
      'argv': argv,
      'paramFiles': params,
    }),
  );
}

bool _equal(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [line] as a POSIX shell reads one word Bazel quoted: `'...'`, with `'\''`
/// for a quote inside.
String _unquote(String line) {
  final out = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == "'") {
      quoted = !quoted;
    } else if (c == r'\' && !quoted && i + 1 < line.length) {
      out.write(line[++i]);
    } else {
      out.write(c);
    }
  }
  return out.toString();
}
