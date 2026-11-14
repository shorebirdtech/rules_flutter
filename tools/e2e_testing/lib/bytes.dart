/// Searching the bytes of a built binary.
library;

/// Whether [needle] occurs in [haystack] as a run of consecutive bytes.
bool containsBytes(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// [text] as UTF-16 little-endian bytes: how binary XML (a compiled
/// `AndroidManifest.xml`) stores its strings.
List<int> utf16leBytes(String text) => [
  for (final unit in text.codeUnits) ...[unit & 0xff, unit >> 8],
];
