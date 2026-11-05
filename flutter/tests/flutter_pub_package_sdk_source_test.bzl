"""Unit tests for how the extension sorts a lock entry by who builds it.

The lock's `source:` says where pub got a package. rules_flutter's answer is
one of a few kinds, and that answer must follow from the entry alone, never
from a list of package names: pub resolves whatever the app's dependency graph
reaches, and a Flutter release adds and drops `sdk: flutter` packages.
Measured against a real `flutter pub get` of an app with `integration_test`
in `dev_dependencies`: the lock gained three `source: sdk` entries,
`integration_test`, `flutter_driver` and `fuchsia_remote_debug_protocol`, the
last of which no list written by hand had named.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:lock_entry_kind.bzl",
    "ENGINE_PROVIDED",
    "FLUTTER_FRAMEWORK",
    "FLUTTER_SOURCE",
    "HOSTED",
    "UNSUPPORTED",
    "lock_entry_kind",
)

def _sdk_entries_are_built_from_the_flutter_source_test_impl(ctx):
    """Every `sdk` entry other than `flutter` and `sky_engine` is built from the Flutter source.

    Including the ones a release adds tomorrow: the classification names only
    the two exceptions, so an `sdk` package nobody has heard of is built from
    the pinned source (and fails there, naming itself, if that source lacks it).
    """
    env = unittest.begin(ctx)

    for name in [
        "flutter_test",
        "flutter_driver",
        "flutter_localizations",
        "flutter_web_plugins",
        "integration_test",
        "a_package_a_future_flutter_adds",
    ]:
        asserts.equals(env, FLUTTER_SOURCE, lock_entry_kind(name, "sdk"), name)

    return unittest.end(env)

def _fuchsia_remote_debug_protocol_is_not_special_cased_test_impl(ctx):
    """`fuchsia_remote_debug_protocol` is classified by the rule every other `sdk` entry follows.

    It is the package an app's lock gains only because `flutter_driver`
    depends on it, so a list of names is what would have left it out.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, FLUTTER_SOURCE, lock_entry_kind("fuchsia_remote_debug_protocol", "sdk"))
    asserts.equals(env, lock_entry_kind("integration_test", "sdk"), lock_entry_kind("fuchsia_remote_debug_protocol", "sdk"))

    return unittest.end(env)

def _the_two_exceptions_keep_their_own_kinds_test_impl(ctx):
    """`flutter` is the framework package, and `sky_engine` is the engine's.

    The framework's shaders are declared in no pubspec, so it keeps the one
    rule that lists them; `sky_engine` needs no repository, the engine toolchain
    provides its `dart:ui`.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, FLUTTER_FRAMEWORK, lock_entry_kind("flutter", "sdk"))
    asserts.equals(env, ENGINE_PROVIDED, lock_entry_kind("sky_engine", "sdk"))

    return unittest.end(env)

def _git_and_path_entries_are_unsupported_test_impl(ctx):
    """A git or path package, or a source rules_flutter has never heard of, is unsupported.

    Even one whose name an `sdk` package has: the source is what decides.
    """
    env = unittest.begin(ctx)

    for source in ["git", "path", "something_new"]:
        asserts.equals(env, UNSUPPORTED, lock_entry_kind("some_package", source), source)
        asserts.equals(env, UNSUPPORTED, lock_entry_kind("integration_test", source), source)

    return unittest.end(env)

def _hosted_entries_are_hosted_test_impl(ctx):
    """A `hosted` entry is fetched from its registry, whatever its name."""
    env = unittest.begin(ctx)

    asserts.equals(env, HOSTED, lock_entry_kind("meta", "hosted"))
    asserts.equals(env, HOSTED, lock_entry_kind("flutter_test", "hosted"))

    return unittest.end(env)

_sdk_entries_are_built_from_the_flutter_source_test = unittest.make(
    _sdk_entries_are_built_from_the_flutter_source_test_impl,
)
_fuchsia_remote_debug_protocol_is_not_special_cased_test = unittest.make(
    _fuchsia_remote_debug_protocol_is_not_special_cased_test_impl,
)
_the_two_exceptions_keep_their_own_kinds_test = unittest.make(
    _the_two_exceptions_keep_their_own_kinds_test_impl,
)
_git_and_path_entries_are_unsupported_test = unittest.make(
    _git_and_path_entries_are_unsupported_test_impl,
)
_hosted_entries_are_hosted_test = unittest.make(
    _hosted_entries_are_hosted_test_impl,
)

def flutter_pub_package_sdk_source_test_suite(name):
    unittest.suite(
        name,
        _sdk_entries_are_built_from_the_flutter_source_test,
        _fuchsia_remote_debug_protocol_is_not_special_cased_test,
        _the_two_exceptions_keep_their_own_kinds_test,
        _git_and_path_entries_are_unsupported_test,
        _hosted_entries_are_hosted_test,
    )
