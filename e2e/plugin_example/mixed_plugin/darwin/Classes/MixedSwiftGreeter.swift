import Foundation

/// The Swift half of the module: public, so a host app reaches it through
/// the framework's Swift interface and its generated header.
@objc public class MixedSwiftGreeter: NSObject {
  /// The Objective-C half's greeting, passed through Swift. Swift sees the
  /// Objective-C class without an import: the two halves are one module.
  @objc public static func greeting() -> String {
    "\(MXDMixedPlugin.greeting()), through Swift"
  }
}
