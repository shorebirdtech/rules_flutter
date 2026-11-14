/// What an app running an integration test asks of the host about a golden, and
/// what the host answers.
///
/// A golden is compared on the host: the app may be on a phone or in a browser
/// and has none of the files, and where the golden is written, and the
/// pictures of a failure kept, is the host's to say. The app asks through the
/// channel it already has to the host, whichever it is (`vm_service_suite_transport.dart`,
/// `cdp_suite_transport.dart`); this is what is asked, the same on both.
///
/// The request is upstream's `VmServiceProxyGoldenFileComparator`'s: an id
/// the answer carries back, the golden's key as `matchesGoldenFile` wrote it,
/// and the picture's bytes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rule_tools/remote_suite.dart';

/// What the app wants done with the picture.
enum GoldenOperation {
  /// Compare it with the golden file.
  compare('compare'),

  /// Write it as the golden file.
  update('update');

  const GoldenOperation(this.key);

  /// The name the app sends.
  final String key;

  /// The operation named [key], or null for none.
  static GoldenOperation? named(String key) =>
      values.where((o) => o.key == key).firstOrNull;
}

/// One request of the app.
class GoldenRequest {
  /// A request the app numbered [id].
  const GoldenRequest({
    required this.id,
    required this.operation,
    required this.key,
    required this.bytes,
  });

  /// What the answer carries back.
  final int id;

  /// What is wanted.
  final GoldenOperation operation;

  /// The golden's key: a path relative to the directory of the test's source.
  final String key;

  /// The picture, as a PNG.
  final Uint8List bytes;
}

/// What the host says to a request: the comparison's result, or why it could
/// not be made, or failed, in the comparator's words.
class GoldenAnswer {
  /// The picture [matched] the golden, or was written as it, to the file
  /// [wrote] when the host knows which.
  const GoldenAnswer.matched(bool this.matched, {this.wrote}) : error = null;

  /// The comparison failed, or could not be made, for [error].
  const GoldenAnswer.failed(String this.error) : matched = null, wrote = null;

  /// Whether the comparison passed, or null when it did not complete.
  final bool? matched;

  /// Why it did not complete, or null.
  final String? error;

  /// The path of the golden file that was written, when one was.
  final String? wrote;
}

/// A channel to an app that can be asked for its goldens: what a
/// [SuiteTransport] to an integration test's app is.
abstract interface class GoldenRequests {
  /// What the app asks, in order. Ends with the channel.
  Stream<GoldenRequest> get goldenRequests;

  /// Tells the app the answer to its request [id].
  Future<void> answerGolden(int id, GoldenAnswer answer);
}

/// The channel to an integration test's app: its suite, and its goldens.
abstract interface class IntegrationSuiteTransport
    implements SuiteTransport, GoldenRequests {}
