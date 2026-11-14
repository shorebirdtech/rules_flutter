"""`digest_problem` is what stands between a download and an unchecked fetch.

The property: only exactly 64 lowercase hex characters is a usable digest.
Empty, short, long, non-hex, upper-case, padded and non-string values are all
refused, each with a reason, so `pinned` can fail before a request is made.
`//tools/dev_tool/test/e2e/digest_missing_e2e_test.dart` observes the refusal
inside real repository rules.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:pinned.bzl", "digest_problem")

_GOOD = "0123456789abcdef" * 4

def _a_sha256_is_usable_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, digest_problem(_GOOD))
    asserts.equals(env, None, digest_problem("f" * 64))
    return unittest.end(env)

def _anything_else_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in [
        "",
        _GOOD[:40],
        _GOOD[:63],
        _GOOD + "0",
        "z" * 64,
        _GOOD.upper(),
        " " + _GOOD[1:],
        _GOOD[:63] + "\n",
        # A digest in another notation, which Bazel would parse as a different
        # algorithm or reject only after the download.
        "sha256-" + _GOOD,
        None,
        64,
        ["a" * 64],
    ]:
        asserts.true(env, digest_problem(bad), "{} was accepted as a digest".format(repr(bad)))
    return unittest.end(env)

_t0_test = unittest.make(_a_sha256_is_usable_test_impl)
_t1_test = unittest.make(_anything_else_is_refused_test_impl)

def pinned_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test)
