"""Unit tests for swift_packages.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swift_packages.bzl", "merge_pins", "parse_package_resolved", "swift_package_repo", "swift_product_label")

_V2 = """{
  "pins" : [
    {
      "identity" : "firebase-ios-sdk",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/firebase/firebase-ios-sdk",
      "state" : {
        "revision" : "dc6dfd442b1f3ec215ed62b8beb2623ffab010d6",
        "version" : "13.1.1"
      }
    },
    {
      "identity" : "promises",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/google/promises.git",
      "state" : {
        "branch" : "main",
        "revision" : "540318ecedd63d883069ae7f1ed811a2df00b6ac"
      }
    }
  ],
  "version" : 2
}"""

def _parse_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = parse_package_resolved(_V2, "Package.resolved")
    asserts.equals(env, ["firebase-ios-sdk", "promises"], [p.identity for p in pins])
    asserts.equals(env, "13.1.1", pins[0].version)
    asserts.equals(env, "", pins[1].version)
    asserts.equals(env, "540318ecedd63d883069ae7f1ed811a2df00b6ac", pins[1].revision)

    # Version 1, as older Xcode writes it.
    v1 = parse_package_resolved("""{"object": {"pins": [{"package": "Promises",
        "repositoryURL": "https://github.com/google/promises.git",
        "state": {"branch": null, "revision": "abc", "version": "2.4.0"}}]}, "version": 1}""", "old")
    asserts.equals(env, [("promises", "abc", "2.4.0")], [(p.identity, p.revision, p.version) for p in v1])
    return unittest.end(env)

parse_test = unittest.make(_parse_test_impl)

def _merge_test_impl(ctx):
    env = unittest.begin(ctx)
    pins = parse_package_resolved(_V2, "a")
    merged = merge_pins([("a", pins), ("b", pins[:1])])
    asserts.equals(env, ["firebase-ios-sdk", "promises"], sorted(merged.keys()))
    return unittest.end(env)

merge_test = unittest.make(_merge_test_impl)

def _names_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "swiftpkg_firebase_ios_sdk", swift_package_repo("firebase-ios-sdk"))
    asserts.equals(env, "@swiftpkg_firebase_ios_sdk//:FirebaseCore", swift_product_label("firebase-ios-sdk", "FirebaseCore"))
    return unittest.end(env)

names_test = unittest.make(_names_test_impl)

def swift_packages_test_suite(name):
    unittest.suite(name, parse_test, merge_test, names_test)
