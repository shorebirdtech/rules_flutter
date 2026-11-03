import 'package:test/test.dart';

import '../private_names.dart';

// The names here are made up; the real list is outside the repository.
const _names = ['Acme', 'widgetco'];

void main() {
  group('parseNames', () {
    test('one per line, comments and blanks dropped', () {
      expect(parseNames('# private\nAcme\n\n  widgetco  \n#x\n'), _names);
    });
    test('a file with no names is empty', () {
      expect(parseNames('\n# only a comment\n'), isEmpty);
    });
  });

  group('findNames', () {
    test('matches regardless of case', () {
      expect(findNames('ACME and WidgetCo', _names), ['Acme', 'widgetco']);
    });
    test('matches next to punctuation, underscores and hyphens', () {
      expect(findNames('acme-cloud', _names), ['Acme']);
      expect(findNames('--config=widgetco_local', _names), ['widgetco']);
      expect(findNames("Acme's", _names), ['Acme']);
      expect(findNames('(acme)', _names), ['Acme']);
    });
    test('matches a name joined into a camelCase identifier', () {
      expect(findNames('AcmeNotes', _names), ['Acme']);
      expect(findNames('myAcme', _names), ['Acme']);
    });
    test('does not match inside a longer word', () {
      expect(findNames('acmeish', _names), isEmpty);
      expect(findNames('pacme', _names), isEmpty);
      expect(findNames('ACMEs', _names), isEmpty);
      expect(findNames('acme2', _names), isEmpty);
    });
    test('finds a later occurrence after an embedded one', () {
      expect(findNames('pacme and acme', _names), ['Acme']);
    });
    test('reports a name once per text', () {
      expect(findNames('acme acme', _names), ['Acme']);
    });
  });

  group('scanText', () {
    test('reports file, line and name', () {
      final hits = scanText(
        'one\ntwo acme\nthree',
        _names,
        where: 'a.txt',
        firstLine: 10,
      );
      expect(hits, [const Hit('a.txt', 11, 'Acme')]);
      expect(hits.single.toString(), 'a.txt:11: private name "Acme"');
    });
  });

  test('scanPath reports the path', () {
    final hits = scanPath('docs/acme_notes.md', _names);
    expect(hits, [const Hit('docs/acme_notes.md', null, 'Acme')]);
    expect(
      hits.single.toString(),
      'docs/acme_notes.md: private name "Acme" in the path',
    );
  });

  group('scanCommitMessage', () {
    test('skips comment lines and everything after the scissors', () {
      const message =
          'fix: x\n'
          '\n'
          'Body about acme.\n'
          '# acme in a comment\n'
          '# ------------------------ >8 ------------------------\n'
          '+acme in the diff\n';
      expect(scanCommitMessage(message, _names), [
        const Hit('commit message', 3, 'Acme'),
      ]);
    });
    test('checks the subject', () {
      expect(scanCommitMessage('feat: widgetco support', _names), [
        const Hit('commit message', 1, 'widgetco'),
      ]);
    });
  });

  group('addedLines', () {
    test('numbers added lines from the hunk headers', () {
      const diff = '''
diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -2,0 +3,2 @@ context
+first
+second
@@ -10 +12 @@
-old
+new
diff --git a/dir/b c.txt b/dir/b c.txt
--- a/dir/b c.txt
+++ b/dir/b c.txt\t
@@ -1 +1 @@
-x
\\ No newline at end of file
+y
''';
      final lines = addedLines(diff);
      expect(
        [for (final l in lines) '${l.path}:${l.line}:${l.text}'],
        ['a.txt:3:first', 'a.txt:4:second', 'a.txt:12:new', 'dir/b c.txt:1:y'],
      );
    });
    test('a new file starts at line 1', () {
      const diff = '''
diff --git a/n.txt b/n.txt
new file mode 100644
--- /dev/null
+++ b/n.txt
@@ -0,0 +1,2 @@
+a
+b
''';
      expect(addedLines(diff).map((l) => l.line), [1, 2]);
    });
    test('a deleted file adds nothing', () {
      const diff = '''
diff --git a/d.txt b/d.txt
deleted file mode 100644
--- a/d.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-a
-b
''';
      expect(addedLines(diff), isEmpty);
    });
    test('an added line that looks like a file header is content', () {
      const diff = '''
diff --git a/a.txt b/a.txt
--- a/a.txt
+++ b/a.txt
@@ -0,0 +1,2 @@
+++ b/other
+acme
''';
      final lines = addedLines(diff);
      expect(lines.map((l) => l.path), ['a.txt', 'a.txt']);
      expect(lines.last.text, 'acme');
    });
  });
}
