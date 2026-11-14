// The golden comparator of an integration test's app, which asks the host.
//
// The app may be on a phone or in a browser: it has none of the golden files,
// and the pictures of a failure and the written golden belong in the test's
// workspace on the host. So `matchesGoldenFile` in an integration test hands the
// picture to the host (`integration_test_runner`), which compares it with the
// one comparison every `flutter_test` here makes, and answers with the result or
// the comparator's own words for why it failed.
//
// The request is upstream's `VmServiceProxyGoldenFileComparator`'s: an id, the
// golden's key as `matchesGoldenFile` wrote it, and the picture's bytes. That
// class is for a phone and refuses a desktop, where `flutter test` compares in
// the app; here the host compares everywhere, since what compares is the
// runner's Bazel comparator and not the app's, and a browser has no VM service
// for upstream's to post through.
//
// There is no update mode in the app: the host writes the picture instead of
// comparing it when the run is `bazel run <test> -- --update-goldens`, as
// `flutter test --update-goldens` makes the web platform's comparator do on the
// host, because an app on a device cannot be handed `autoUpdateGoldenFiles`.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// What the host answered: whether the picture matched, or why it did not
/// complete.
class GoldenReply {
  /// The picture [matched] the golden, or was written as it.
  const GoldenReply.matched(bool this.matched) : error = null;

  /// The comparison failed, or could not be made, for [error].
  const GoldenReply.failed(String this.error) : matched = null;

  /// Whether it matched, or null when [error] says why not.
  final bool? matched;

  /// Why it failed, in the comparator's words, or null.
  final String? error;
}

/// Asks the host to [operation] (`compare` or `update`) the golden [key] with
/// [bytes].
typedef AskHostAboutGolden = Future<GoldenReply> Function(
  String operation,
  String key,
  Uint8List bytes,
);

/// A [GoldenFileComparator] whose comparison is the host's.
class HostGoldenFileComparator extends GoldenFileComparator {
  /// Compares through [ask].
  HostGoldenFileComparator(this._ask);

  final AskHostAboutGolden _ask;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async =>
      _matched(await _ask('compare', '$golden', imageBytes));

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {
    _matched(await _ask('update', '$golden', imageBytes));
  }

  /// A failure is a [TestFailure], which `matchesGoldenFile` reports as the
  /// matcher's own mismatch, with the comparator's message.
  bool _matched(GoldenReply reply) {
    final error = reply.error;
    if (error != null) throw TestFailure(error);
    return reply.matched!;
  }
}
