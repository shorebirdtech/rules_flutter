/// Finds the download calls in Starlark sources and says which of them could
/// fetch bytes without a pinned digest.
///
/// The property this serves: every byte rules_flutter downloads is checked
/// against a digest it pinned. In a repository rule that is the `sha256`
/// argument of `repository_ctx.download` / `download_and_extract`; an empty
/// string there turns the check off, silently. So a download site is *unpinned*
/// when its call
///
///  * has no `sha256` (or `integrity`) argument, or
///  * passes the empty string, or
///  * passes an expression that, at its top level, falls back to the empty
///    string (`table.get(key, "")`, `x if x else ""`, `x or ""`).
///
/// This reads source text, so it is a guard against the shapes that have gone
/// wrong, not a proof: a digest computed some other way that happens to be
/// empty at run time is invisible to it. The fetch tests in
/// `tools/dev_tool/test/e2e/digest_*` observe the behaviour.
library;

/// One call of `*.download(...)` or `*.download_and_extract(...)`.
class DownloadSite {
  const DownloadSite({
    required this.file,
    required this.line,
    required this.callee,
    required this.digest,
    required this.text,
  });

  final String file;

  /// 1-based line of the call.
  final int line;

  /// `download` or `download_and_extract`.
  final String callee;

  /// The text of the `sha256`/`integrity` argument, or null if there is none.
  final String? digest;

  /// The whole call, as written.
  final String text;

  String get where => '$file:$line';

  /// Why this site can fetch unverified bytes, or null if it cannot.
  ///
  /// Only the shapes that *are* an empty digest are named: the literal, and a
  /// top-level fallback to it (`table.get(key, "")`, `x if x else ""`,
  /// `x or ""`). A digest passed through another call, `check(table.get(k, ""))`,
  /// is that call's to refuse, and what it does is for the fetch tests to see;
  /// this cannot tell a check from a wrapper.
  String? get problem {
    final d = digest;
    if (d == null) return '$callee has no sha256 argument';
    final v = d.trim();
    if (v == '""' || v == "''") return '$callee passes an empty sha256';
    if (_fallsBackToEmpty(v)) {
      return '$callee falls back to an empty sha256 ($v)';
    }
    return null;
  }
}

final _emptyString = RegExp(r"""^(""|'')$""");

/// True if [expr] is, at its top level, a lookup or a choice that can come out
/// as the empty string.
bool _fallsBackToEmpty(String expr) {
  final masked = _mask(expr);
  // `x if c else ""` and `x or ""`.
  var depth = 0;
  for (var i = 0; i < masked.length; i++) {
    final c = masked[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (depth != 0) continue;
    for (final keyword in ['else', 'or']) {
      final boundary = i == 0 || !RegExp(r'\w').hasMatch(masked[i - 1]);
      if (boundary && masked.startsWith(keyword, i)) {
        final rest = masked.substring(i + keyword.length).trim();
        if (_emptyString.hasMatch(rest)) return true;
      }
    }
  }
  // `receiver.get(key, "")` as the whole expression.
  final get = RegExp(r'^[\w.\[\]"\x27]+\.get\(').firstMatch(masked);
  if (get != null && masked.endsWith(')')) {
    final inner = masked.substring(get.end, masked.length - 1);
    final args = _splitArgs(inner);
    if (args.length == 2) {
      final last = inner.substring(args[1].$1, args[1].$2).trim();
      if (_emptyString.hasMatch(last)) return true;
    }
  }
  return false;
}

/// Source with comments blanked and string contents replaced by `x`, with the
/// same length and line breaks as [source], so offsets match.
String _mask(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == '#') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (c == '"' || c == "'") {
      final triple = source.startsWith(c * 3, i);
      final quote = triple ? c * 3 : c;
      out.write(quote);
      i += quote.length;
      while (i < source.length) {
        if (source[i] == '\\' && i + 1 < source.length) {
          out.write('xx');
          i += 2;
        } else if (source.startsWith(quote, i)) {
          out.write(quote);
          i += quote.length;
          break;
        } else {
          out.write(source[i] == '\n' ? '\n' : 'x');
          i++;
        }
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// Splits [args] (the text between a call's parentheses, masked) at top-level
/// commas, returning (start, end) offsets into it.
List<(int, int)> _splitArgs(String masked) {
  final parts = <(int, int)>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < masked.length; i++) {
    final c = masked[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      parts.add((start, i));
      start = i + 1;
    } else if (c == '"' || c == "'") {
      // Skip the (masked) string.
      final quote = masked.startsWith(c * 3, i) ? c * 3 : c;
      i += quote.length;
      while (i < masked.length && !masked.startsWith(quote, i)) {
        i++;
      }
      i += quote.length - 1;
    }
  }
  if (masked.substring(start).trim().isNotEmpty) {
    parts.add((start, masked.length));
  }
  return parts;
}

/// The download calls in [source], which was read from [file].
List<DownloadSite> findDownloadSites(String file, String source) {
  final masked = _mask(source);
  final calls = RegExp(r'\.(download_and_extract|download)\s*\(');
  final sites = <DownloadSite>[];
  for (final m in calls.allMatches(masked)) {
    final open = m.end - 1;
    var depth = 0;
    var close = -1;
    for (var i = open; i < masked.length; i++) {
      if (masked[i] == '(') depth++;
      if (masked[i] == ')') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) continue;
    final bodyMasked = masked.substring(open + 1, close);
    final body = source.substring(open + 1, close);
    String? digest;
    for (final (s, e) in _splitArgs(bodyMasked)) {
      final arg = bodyMasked.substring(s, e);
      final named = RegExp(r'^\s*(sha256|integrity)\s*=(?!=)').firstMatch(arg);
      if (named != null) {
        digest = body.substring(s + named.end, e).trim();
      }
    }
    sites.add(
      DownloadSite(
        file: file,
        line: '\n'.allMatches(source.substring(0, m.start)).length + 1,
        callee: m.group(1)!,
        digest: digest,
        text: source.substring(m.start, close + 1),
      ),
    );
  }
  return sites;
}
