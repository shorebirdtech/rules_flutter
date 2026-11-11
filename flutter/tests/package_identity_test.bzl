"""Tests of the package identity (purl) a fetched pub package repository states.

A repository `flutter_pub_package` fetches from a pub registry says what it holds
through Bazel's supply-chain metadata, as rules_dart's do: a `package_metadata`
target with the package's `pkg:pub` purl, which the repository's `REPO.bazel`
attaches to every target in it. The unit tests show what the BUILD files it
writes contain. That a package really fetched carries the purl its lock entry
gives is `fetched_purls_test`'s (`purls.bzl`).
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "pub_git_purl", "pub_hosted_purl", "pub_package_identity")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_dart_member_build_content",
    "make_flutter_member_build_content",
)

_SHA = "d0481093c50b1da8910eb0bb301626d4d8eb7284aa739614d2b394ee09e3ea04"
_COMMIT = "0123456789abcdef0123456789abcdef01234567"

def _identity_target(purl):
    return '''
package_metadata(
    name = "package-metadata",
    purl = "%s",
    visibility = ["//visibility:public"],
)
''' % purl

def _members_state_their_purl_test_impl(ctx):
    env = unittest.begin(ctx)
    purls = [
        pub_hosted_purl("args", "2.7.0", _SHA),
        pub_git_purl("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args"),
    ]
    for purl in purls:
        dart = make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0", purl = purl)
        flutter = make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0", purl = purl, plugin_platforms = {"web": {"pluginClass": "WebPlugin"}})
        for content in [dart, flutter]:
            asserts.true(env, _identity_target(purl) in content, content)

            # Every load comes before the first target.
            asserts.true(env, content.rfind("\nload(") < content.find("\npackage_metadata("), content)
    asserts.equals(env, 'repo(default_package_metadata = ["//:package-metadata"])\n', pub_package_identity(purls[0]).repo_file)
    return unittest.end(env)

def _members_without_a_purl_state_none_test_impl(ctx):
    """A package of the user's own (a path package) states its own, if any."""
    env = unittest.begin(ctx)
    for content in [
        make_dart_member_build_content("args", "3.4", [], "", version = "2.7.0"),
        make_flutter_member_build_content("args", "3.4", [], "", version = "2.7.0"),
    ]:
        asserts.true(env, "\npackage_metadata(" not in content and "package_metadata.bzl" not in content, content)
    return unittest.end(env)

def _purls_follow_the_lock_entry_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg:pub/args@2.7.0?checksum=sha256:" + _SHA, pub_hosted_purl("args", "2.7.0", _SHA))
    asserts.equals(
        env,
        "pkg:pub/args@2.7.0?vcs_url=git%2Bhttps:%2F%2Fexample.com%2Fargs.git%40" + _COMMIT + "%23pkgs%2Fargs",
        pub_git_purl("args", "2.7.0", "https://example.com/args.git", _COMMIT, "pkgs/args"),
    )
    return unittest.end(env)

_members_state_their_purl_test = unittest.make(_members_state_their_purl_test_impl)
_members_without_a_purl_state_none_test = unittest.make(_members_without_a_purl_state_none_test_impl)
_purls_follow_the_lock_entry_test = unittest.make(_purls_follow_the_lock_entry_test_impl)

def package_identity_test_suite(name):
    """Registers the package identity unit tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    unittest.suite(
        name,
        _members_state_their_purl_test,
        _members_without_a_purl_state_none_test,
        _purls_follow_the_lock_entry_test,
    )
