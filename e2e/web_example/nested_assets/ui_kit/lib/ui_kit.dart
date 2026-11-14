/// A library with an asset of its own, in a package below the workspace root.
///
/// The asset is bundled as `packages/ui_kit/assets/greeting.txt`, which is a
/// path in this package, not in the workspace.
library;

/// The key the library's asset is bundled under.
const greetingKey = 'packages/ui_kit/assets/greeting.txt';
