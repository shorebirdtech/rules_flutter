import Foundation

/// The Swift half of the module: public, so a host app reaches it through
/// the framework's Swift interface and its generated header.
@objc public class MixedSwiftGreeter: NSObject {
  /// A greeting made in Swift.
  @objc public static func greeting() -> String {
    "Hello from Swift"
  }
}
