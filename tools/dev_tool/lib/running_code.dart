/// What the app's Dart code is, once a command is over.
///
/// Its own library because the question is asked at both ends of the pipeline
/// and the answers must be the same word: `VmServiceClient` knows which phase
/// of an apply failed, and `CommandReport` knows what to tell a client. A
/// second enum, or a sentence composed by hand at either end, is how the two
/// would come to disagree.
library;

/// What the app's Dart code is, now the command is over.
///
/// The question a failed reload cannot answer in prose without guessing, and
/// the one its reader most needs: is the app still running what it was?
///
/// Deliberately not derived from success: a failure can leave the app running
/// the new code (`AppliedThenThrew`), and a success can leave it running the
/// old one (an empty delta).
enum RunningCode {
  /// The app is running the same program it was: whatever this command sent,
  /// if anything, the loaded code is what it already had.
  ///
  /// Three shapes reach it. Nothing was ever sent — a refusal, a pre-compile
  /// rebuild that broke, a compile that produced no delta. A delivery was
  /// demonstrably refused before it took effect (`ApplyFailed`). Or a hot
  /// reload completed and carried nothing new: an empty delta, where every file
  /// the compiler was asked for was byte-identical to what the app already had.
  ///
  /// A restart that completed is never this value, whatever it sent — see
  /// [updated].
  unchanged,

  /// The VM took the code. It may be unhappy about it — see `AppliedThenThrew`
  /// — but it is running it.
  ///
  /// Every completed restart lands here, even one whose files all match what
  /// the last reload sent. It loaded the whole program into a new isolate and
  /// ran `main()` on it, so initializers a reload never re-runs ran again and
  /// the state is gone: the app is running a program it was not running before.
  updated,

  /// Nobody said, and nothing here may guess. A device that never answered
  /// within the apply's budget is the member this exists for: the RPC it
  /// stopped waiting on may have landed, and the connection was dropped before
  /// anything could ask.
  ///
  /// A refusal is not one of these: `VmServiceClient` never raises one after an
  /// app has taken what was sent.
  unknown,
}
