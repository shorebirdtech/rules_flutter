"""Unit tests for the library repository of a built pub package.

A package's library is its dependency cycle built as one target (Bazel has no
cycles; pub does). What is decided here, away from a fetch: which repository
and target another package depends on, what the library's BUILD file says,
and that an overlay cannot be part of a cycle.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_index.bzl", "index_repo", "library_label", "library_repo", "source_repo")
load("//flutter/private:flutter_pub_library_repo.bzl", "make_alias_build_content", "make_library_build_content", "overlay_in_cycle_error")

def _repositories_are_named_by_their_part_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "hub__dio", source_repo("hub", "dio"))
    asserts.equals(env, "hub_lib__dio", library_repo("hub", "dio"))
    asserts.equals(env, "hub_index", index_repo("hub"))

    # A built package is depended on through its library; the lock's other
    # entries (package:flutter, a stub) are their own.
    index = struct(built = {"dio": True}, other = {"flutter": True})
    asserts.equals(env, "@hub_lib__dio//:dio", library_label("hub", index, "dio"))
    asserts.equals(env, "@hub__flutter//:flutter", library_label("hub", index, "flutter"))

    return unittest.end(env)

repositories_are_named_by_their_part_test = unittest.make(_repositories_are_named_by_their_part_test_impl)

def _a_cycle_is_one_library_over_its_members_test_impl(ctx):
    env = unittest.begin(ctx)

    flutter = make_library_build_content(
        name = "dio",
        members = ["@hub__dio//:dio", "@hub__dio_web_adapter//:dio_web_adapter"],
        deps = ["@hub_lib__path//:path"],
        flutter = True,
    )
    asserts.true(env, 'load("@rules_flutter//flutter/private:flutter_pub_library.bzl", "flutter_pub_library")' in flutter, flutter)
    asserts.true(env, '\nflutter_pub_library(\n    name = "dio",' in flutter, flutter)
    asserts.true(env, '    members = ["@hub__dio//:dio", "@hub__dio_web_adapter//:dio_web_adapter"],' in flutter, flutter)
    asserts.true(env, '    deps = ["@hub_lib__path//:path"],' in flutter, flutter)

    # A cycle with nothing of Flutter's is rules_dart's own library.
    dart = make_library_build_content(
        name = "path",
        members = ["@hub__path//:path"],
        deps = [],
        flutter = False,
    )
    asserts.true(env, 'load("@rules_dart//dart/pub:pub_library.bzl", "pub_library")' in dart, dart)
    asserts.true(env, "\npub_library(\n" in dart, dart)
    asserts.true(env, "    deps = [],\n" in dart, dart)

    return unittest.end(env)

a_cycle_is_one_library_over_its_members_test = unittest.make(_a_cycle_is_one_library_over_its_members_test_impl)

def _a_library_exports_its_members_android_libraries_on_android_test_impl(ctx):
    """A library lists its members' Android libraries under `exports`, on Android only.

    `exports` is the one attribute rules_android's dex aspect follows from the
    library to them, so an APK that depends on the library dexes them.
    """
    env = unittest.begin(ctx)

    content = make_library_build_content(
        name = "dio",
        members = ["@hub__dio//:dio"],
        deps = [],
        flutter = True,
        android_libs = ["@hub__dio//android:lib"],
    )
    asserts.true(
        env,
        '    exports = select({\n        "@platforms//os:android": ["@hub__dio//android:lib"],\n        "//conditions:default": [],\n    }),\n' in content,
        content,
    )

    # No Android library, no attribute: nothing loads an `android/` package.
    asserts.false(env, "exports" in make_library_build_content("dio", ["@hub__dio//:dio"], [], True), "exports without a library")

    return unittest.end(env)

a_library_exports_its_members_android_libraries_on_android_test = unittest.make(_a_library_exports_its_members_android_libraries_on_android_test_impl)

def _package_test_carries_the_runner_test_impl(ctx):
    """`dart_test` runs tests through the runner on its direct `package:test`."""
    env = unittest.begin(ctx)

    content = make_library_build_content(
        name = "test",
        members = ["@hub__test//:test"],
        deps = ["@hub_lib__test_api//:test_api"],
        flutter = False,
    )
    asserts.true(env, '\npub_test_runner(\n    name = "test",' in content, content)
    asserts.true(env, '    library = ":test_library",' in content, content)
    asserts.true(env, '\npub_library(\n    name = "test_library",' in content, content)
    asserts.true(env, '    members = ["@hub__test//:test"],' in content, content)

    # Any other package is its library alone.
    asserts.false(env, "pub_test_runner" in make_library_build_content("test_api", ["@hub__test_api//:test_api"], [], False))

    return unittest.end(env)

package_test_carries_the_runner_test = unittest.make(_package_test_carries_the_runner_test_impl)

def _the_others_of_a_cycle_alias_its_library_test_impl(ctx):
    env = unittest.begin(ctx)

    content = make_alias_build_content("dio_web_adapter", "@hub_lib__dio//:dio")
    asserts.true(env, 'name = "dio_web_adapter",' in content, content)
    asserts.true(env, 'actual = "@hub_lib__dio//:dio",' in content, content)

    return unittest.end(env)

the_others_of_a_cycle_alias_its_library_test = unittest.make(_the_others_of_a_cycle_alias_its_library_test_impl)

def _an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test_impl(ctx):
    env = unittest.begin(ctx)

    message = overlay_in_cycle_error("jni", ["jni", "jni_helper", "jni_other"])
    asserts.true(env, "package `jni` is built from a plugin overlay" in message, message)
    asserts.true(env, "`jni_helper`, `jni_other`" in message, message)
    asserts.false(env, "with `jni`" in message, message)

    return unittest.end(env)

an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test = unittest.make(
    _an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test_impl,
)

def flutter_pub_library_repo_test_suite(name):
    unittest.suite(
        name,
        repositories_are_named_by_their_part_test,
        a_cycle_is_one_library_over_its_members_test,
        a_library_exports_its_members_android_libraries_on_android_test,
        package_test_carries_the_runner_test,
        the_others_of_a_cycle_alias_its_library_test,
        an_overlay_in_a_cycle_is_refused_naming_it_and_the_cycle_test,
    )
