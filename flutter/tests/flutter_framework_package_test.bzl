"""Unit tests for the framework spoke's generated BUILD content.

Only `package:flutter` has a spoke of its own (`flutter_framework_package`):
its shaders are declared in no pubspec, so they cannot ride the pub-asset
channel the other Flutter SDK packages are built through.

The fidelity claim under test: pub writes a `languageVersion` for every
Flutter SDK package, derived from that package's own `environment.sdk`.
Measured against a real `flutter pub get` (Flutter 3.41.6, whose
`packages/flutter/pubspec.yaml` declares `^3.9.0-0`): pub wrote
`"languageVersion": "3.9"` for `flutter`, `flutter_test`, `sky_engine`,
`flutter_localizations` and `flutter_web_plugins` alike. A spoke that
emits no language version hands the package the *current* SDK's
language version instead — silently more permissive than pub.

What the repository rule reads out of the pubspec (the constraint, the runtime
dependencies) is tested where the rule runs, against a pubspec read the way pub
reads it: `tools/dev_tool/test/e2e/framework_pubspec_e2e_test.dart`. What is
tested here is the derivation from the constraint and the generated BUILD file.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version")
load("//flutter/private:flutter_framework_package.bzl", "make_flutter_framework_build_content")

def _derives_the_language_version_from_the_sdk_constraint_test_impl(ctx):
    """`^3.11.0-0` yields `3.11` — the prerelease suffix is not a language version.

    Every Flutter SDK package pins a `-0` prerelease floor so that a beta of
    the same triple satisfies it. Pub drops the suffix before formatting;
    ground-truthed above against a real lockfile-and-`pub get` pair.
    """
    env = unittest.begin(ctx)

    asserts.equals(env, "3.11", derive_language_version("^3.11.0-0"))

    return unittest.end(env)

def _flutter_spoke_declares_its_language_version_test_impl(ctx):
    """`package:flutter` builds a flutter_library carrying the derived version."""
    env = unittest.begin(ctx)

    content = make_flutter_framework_build_content(
        deps = ["@hub__meta//:meta"],
        language_version = "3.11",
    )

    asserts.true(env, "flutter_library(" in content, content)
    asserts.true(env, 'language_version = "3.11",' in content, content)

    # The shader channel is what makes this spoke a flutter_library rather
    # than a dart_library; adding a language version must not disturb it.
    asserts.true(env, 'shaders = glob(["lib/src/material/shaders/*.frag"])' in content, content)
    asserts.true(env, '"@hub__meta//:meta",' in content, content)

    # An SDK package is the same under every web compiler.
    asserts.true(env, "\n    web_compiler_independent = True," in content, content)

    return unittest.end(env)

_derives_the_language_version_from_the_sdk_constraint_test = unittest.make(
    _derives_the_language_version_from_the_sdk_constraint_test_impl,
)
_flutter_spoke_declares_its_language_version_test = unittest.make(
    _flutter_spoke_declares_its_language_version_test_impl,
)

def flutter_framework_package_test_suite(name):
    unittest.suite(
        name,
        _derives_the_language_version_from_the_sdk_constraint_test,
        _flutter_spoke_declares_its_language_version_test,
    )
