// Finds names of private projects in text. This library is pure: reading the
// list of names, running git and reporting are in check_private_names.dart.
//
// The list of names is not in this repository, because publishing it would
// publish the names. See check_private_names.dart.

/// One place a private name was found.
class Hit {
  const Hit(this.where, this.line, this.name);

  /// A file path, or `commit message`.
  final String where;

  /// The 1-based line, or null when [where] itself (a path) holds the name.
  final int? line;

  /// The name as the list spells it.
  final String name;

  @override
  String toString() => line == null
      ? '$where: private name "$name" in the path'
      : '$where:$line: private name "$name"';

  @override
  bool operator ==(Object other) =>
      other is Hit &&
      other.where == where &&
      other.line == line &&
      other.name == name;

  @override
  int get hashCode => Object.hash(where, line, name);
}

/// A line the staged diff adds.
class AddedLine {
  const AddedLine(this.path, this.line, this.text);
  final String path;
  final int line;
  final String text;
}

/// The names in the contents of a names file: one per line, blank lines and
/// `#` comments ignored, surrounding whitespace trimmed.
List<String> parseNames(String contents) => [
  for (final raw in contents.split('\n'))
    if (raw.trim() case final line when line.isNotEmpty && line[0] != '#') line,
];

bool _isLower(String c) => c.toLowerCase() == c && c.toUpperCase() != c;
bool _isUpper(String c) => c.toUpperCase() == c && c.toLowerCase() != c;
bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;
bool _isAlnum(String c) => _isLower(c) || _isUpper(c) || _isDigit(c);

/// Whether the match of [length] characters at [start] in [line] stands on its
/// own as a word: not inside a longer word. Punctuation, `_`, `-` and digits'
/// absence all count as a boundary, and so does a camelCase hump on either
/// side (`fooAcme`, `AcmeNotes`), because a name joined into an
/// identifier is still the name.
bool _atWordBoundary(String line, int start, int length) {
  final end = start + length;
  if (start > 0) {
    final before = line[start - 1];
    final camelHump = _isLower(before) && _isUpper(line[start]);
    if (_isAlnum(before) && !camelHump) return false;
  }
  if (end < line.length) {
    final after = line[end];
    final camelHump = _isUpper(after) && _isLower(line[end - 1]);
    if (_isAlnum(after) && !camelHump) return false;
  }
  return true;
}

/// The names from [names] that appear in [text], case-insensitively, as words.
/// Each name is reported once per call, in the order [names] lists them.
List<String> findNames(String text, List<String> names) {
  final lower = text.toLowerCase();
  final found = <String>[];
  for (final name in names) {
    final needle = name.toLowerCase();
    var from = 0;
    while (true) {
      final at = lower.indexOf(needle, from);
      if (at < 0) break;
      if (_atWordBoundary(text, at, needle.length)) {
        found.add(name);
        break;
      }
      from = at + 1;
    }
  }
  return found;
}

/// The hits in [text], line by line. [firstLine] numbers its first line.
List<Hit> scanText(
  String text,
  List<String> names, {
  required String where,
  int firstLine = 1,
}) {
  final hits = <Hit>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final name in findNames(lines[i], names)) {
      hits.add(Hit(where, firstLine + i, name));
    }
  }
  return hits;
}

/// The hits in a path: its directories and file name.
List<Hit> scanPath(String path, List<String> names) => [
  for (final name in findNames(path, names)) Hit(path, null, name),
];

/// The hits in a commit message as `git commit` receives it: lines starting
/// with `#` are comments, and nothing after the `>8` scissors line is part of
/// the message. Line numbers are those of the file.
List<Hit> scanCommitMessage(String message, List<String> names) {
  final hits = <Hit>[];
  final lines = message.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith('# ------------------------ >8')) break;
    if (line.startsWith('#')) continue;
    for (final name in findNames(line, names)) {
      hits.add(Hit('commit message', i + 1, name));
    }
  }
  return hits;
}

final _hunkHeader = RegExp(r'^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

/// The lines added by [diff], the output of `git diff -U0`. A deleted file
/// adds none.
List<AddedLine> addedLines(String diff) {
  final added = <AddedLine>[];
  String? path;
  var oldLeft = 0, newLeft = 0, nextLine = 0;
  for (final line in diff.split('\n')) {
    if (oldLeft > 0 || newLeft > 0) {
      if (line.startsWith('+')) {
        added.add(AddedLine(path!, nextLine, line.substring(1)));
        nextLine++;
        newLeft--;
      } else if (line.startsWith('-')) {
        oldLeft--;
      }
      // `\ No newline at end of file` belongs to neither side.
      continue;
    }
    if (line.startsWith('+++ ')) {
      var target = line.substring(4);
      // Git ends a path that holds a space with a tab.
      final tab = target.indexOf('\t');
      if (tab >= 0) target = target.substring(0, tab);
      if (target.length >= 2 &&
          target.startsWith('"') &&
          target.endsWith('"')) {
        target = target.substring(1, target.length - 1);
      }
      path = target == '/dev/null'
          ? null
          : (target.startsWith('b/') ? target.substring(2) : target);
    } else if (_hunkHeader.firstMatch(line) case final m?) {
      oldLeft = int.parse(m[1] ?? '1');
      nextLine = int.parse(m[2]!);
      newLeft = int.parse(m[3] ?? '1');
    }
  }
  return added;
}
