/// The app went away before its suite could be reached, whatever carries the
/// suite.
library;

/// The app ended, or its page was lost, before it started the suite the host
/// drives, with why.
///
/// Distinct from a transport lost mid-suite, which a `RemoteSuiteDriver`
/// reports as the failure of the test it interrupted: here there is no test, and
/// the run fails with the reason.
abstract class LostBeforeSuite implements Exception {
  /// Says what became of the app.
  LostBeforeSuite(this.reason);

  /// How the app ended, in the device's words.
  final String reason;
}
