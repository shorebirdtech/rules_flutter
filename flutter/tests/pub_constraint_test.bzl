"""`allows` answers a pub version constraint the way `package:pub_semver` does.

Each case below is a verdict pub_semver gives for the same text. The ones that
differ from npm's semver are the point: a pre-release is judged by its number
alone, and a plain-release exclusive maximum excludes that release's
pre-releases.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:pub_constraint.bzl",
    "allows",
    "compare_versions",
    "constraint_problem",
    "parse_version",
    "version_problem",
)

def _check(env, constraint, allowed = [], refused = []):
    for v in allowed:
        asserts.true(env, allows(constraint, v), "`{}` should allow {}".format(constraint, v))
    for v in refused:
        asserts.false(env, allows(constraint, v), "`{}` should refuse {}".format(constraint, v))

def _caret_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, "^1.2.3", ["1.2.3", "1.2.4", "1.9.9", "1.10.0", "1.2.3+1"], ["1.2.2", "1.2.3-pre", "2.0.0", "0.9.0"])
    _check(env, "^0.13.0", ["0.13.0", "0.13.9"], ["0.12.9", "0.14.0", "1.0.0"])
    _check(env, "^0.2.3", ["0.2.3", "0.2.9"], ["0.2.2", "0.3.0"])

    # pub_semver's next breaking version of 0.0.z is the next minor, not the next patch.
    _check(env, "^0.0.3", ["0.0.3", "0.0.4", "0.0.99"], ["0.0.2", "0.1.0"])
    _check(env, "^ 1.4.0", ["1.4.0"], ["1.3.9", "2.0.0"])
    return unittest.end(env)

def _caret_pre_release_test_impl(ctx):
    env = unittest.begin(ctx)

    # The upper bound's own pre-releases are outside.
    _check(env, "^1.2.3", [], ["2.0.0-dev", "2.0.0-0", "2.0.0-alpha"])
    _check(env, "^1.2.3", ["1.9.9-beta"], [])
    _check(env, "^0.13.0", [], ["0.14.0-dev"])

    # A pre-release minimum admits later pre-releases of the same release.
    _check(env, "^1.0.0-alpha", ["1.0.0-alpha", "1.0.0-beta", "1.0.0", "1.5.0-dev"], ["1.0.0-0", "2.0.0-0", "2.0.0"])
    return unittest.end(env)

def _ordering_test_impl(ctx):
    env = unittest.begin(ctx)
    ordered = [
        "0.9.9",
        "1.0.0-0",
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
        "1.0.0+1",
        "1.0.0+2",
        "1.0.0+10",
        "1.0.0+a",
        "1.0.1-0",
        "1.0.1",
        "1.1.0",
        "2.0.0",
        "10.0.0",
    ]
    for i in range(len(ordered)):
        for j in range(len(ordered)):
            a = parse_version(ordered[i])
            b = parse_version(ordered[j])
            want = 0 if i == j else (-1 if i < j else 1)
            asserts.equals(env, want, compare_versions(a, b), "{} vs {}".format(ordered[i], ordered[j]))

    # Leading zeros do not change the number.
    asserts.equals(env, 0, compare_versions(parse_version("01.02.03-004"), parse_version("1.2.3-4")))
    return unittest.end(env)

def _upper_bound_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, "<2.0.0", ["1.9.9", "0.0.1", "1.0.0-pre"], ["2.0.0", "2.0.0-dev", "2.0.0-0", "2.0.1"])
    _check(env, "<=2.0.0", ["2.0.0", "2.0.0-dev", "1.0.0"], ["2.0.0+1", "2.0.1"])
    _check(env, "<2.0.0-dev", ["1.9.9", "2.0.0-alpha"], ["2.0.0-dev", "2.0.0-rc", "2.0.0"])
    _check(env, "<2.0.0+3", ["2.0.0-dev", "2.0.0", "2.0.0+2"], ["2.0.0+3", "2.0.0+4"])
    return unittest.end(env)

def _lower_bound_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, ">=1.0.0", ["1.0.0", "1.0.1", "99.0.0", "1.0.0+1"], ["0.9.9", "1.0.0-rc.1"])
    _check(env, ">1.0.0", ["1.0.1", "1.0.0+1"], ["1.0.0", "0.9.9", "1.0.0-rc.1"])
    _check(env, ">=1.0.0-0", ["1.0.0-0", "1.0.0-alpha", "1.0.0"], ["0.9.9"])
    return unittest.end(env)

def _ranges_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, ">=3.9.0 <4.0.0", ["3.9.0", "3.12.1", "3.99.0-beta"], ["3.8.9", "4.0.0", "4.0.0-dev"])
    _check(env, ">=1.0.0-0 <2.0.0", ["1.0.0-0", "1.0.0-alpha", "1.5.0"], ["0.9.9", "2.0.0-0", "2.0.0"])
    _check(env, ">1.0.0 <=2.0.0", ["1.0.1", "2.0.0"], ["1.0.0", "2.0.1"])
    _check(env, "  >=1.0.0   <2.0.0  ", ["1.5.0"], ["2.0.0"])
    _check(env, ">= 1.0.0 < 2.0.0", ["1.5.0"], ["2.0.0"])

    # The tightest bound of each side wins, whatever the order.
    _check(env, ">=1.0.0 >=1.5.0 <3.0.0 <2.0.0", ["1.5.0", "1.9.0"], ["1.4.0", "2.0.0"])
    _check(env, "<2.0.0 >=1.0.0", ["1.0.0"], ["2.0.0", "0.9.0"])

    # A pre-release minimum on the same release keeps that release's pre-releases below the maximum.
    _check(env, ">=2.0.0-dev <2.0.0", ["2.0.0-dev", "2.0.0-rc.1"], ["2.0.0", "1.9.0"])

    # Contradictory bounds allow nothing.
    _check(env, ">=2.0.0 <1.0.0", [], ["0.5.0", "1.5.0", "2.5.0"])
    _check(env, ">1.0.0 <=1.0.0", [], ["1.0.0"])
    _check(env, ">=1.0.0 <1.0.0", [], ["1.0.0"])
    return unittest.end(env)

def _exact_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, "0.13.0", ["0.13.0"], ["0.13.1", "0.12.9", "0.13.0-pre", "0.13.0+1"])
    _check(env, "1.2.3-beta.1", ["1.2.3-beta.1"], ["1.2.3", "1.2.3-beta.2", "1.2.3-beta"])
    _check(env, "1.2.3+4", ["1.2.3+4"], ["1.2.3", "1.2.3+5"])
    _check(env, " 1.2.3 ", ["1.2.3"], ["1.2.4"])
    return unittest.end(env)

def _any_test_impl(ctx):
    env = unittest.begin(ctx)
    for c in ["any", "", "  ", " any "]:
        _check(env, c, ["0.0.0", "1.2.3", "1.0.0-alpha", "99.0.0+1", "2.0.0-dev"], [])
    return unittest.end(env)

def _build_metadata_test_impl(ctx):
    env = unittest.begin(ctx)
    _check(env, ">=1.0.0+2", ["1.0.0+2", "1.0.0+3", "1.0.1"], ["1.0.0", "1.0.0+1"])
    _check(env, "^1.0.0", ["1.0.0+1", "1.5.0+build.7"], [])
    asserts.equals(env, ["b", 7], parse_version("1.0.0+b.7").build)
    asserts.equals(env, ["alpha", 1, "x-y"], parse_version("1.0.0-alpha.1.x-y").pre)
    return unittest.end(env)

def _garbage_test_impl(ctx):
    env = unittest.begin(ctx)
    for bad in [
        "garbage",
        "1.2",
        "1",
        "v1.2.3",
        "^",
        "^abc",
        "^1.2.3 <2.0.0",
        ">=",
        ">= x",
        ">=1.0.0 and <2.0.0",
        ">=1.0.0, <2.0.0",
        "1.2.3-",
        "1.2.3+",
        "1.2.3.4",
        "1.2.3-a..b",
        "=1.2.3",
        "~1.2.3",
        "1.x",
        "*",
        "any 1.0.0",
        None,
        3,
    ]:
        problem = constraint_problem(bad)
        asserts.true(env, problem, "{} was accepted as a constraint".format(repr(bad)))
        if type(bad) == "string":
            asserts.true(env, bad in problem, "the problem for {} does not quote it: {}".format(repr(bad), problem))
    for good in ["", "any", "1.2.3", "^1.2.3", ">=1.0.0 <2.0.0", "<=1.0.0-0"]:
        asserts.equals(env, None, constraint_problem(good), good)

    for bad in ["", "1.2", "1.2.3.4", "^1.2.3", ">=1.2.3", "1.2.3-", "1.2.3+", "x", " 1.2.3", "1.2.3 ", None, 3]:
        problem = version_problem(bad)
        asserts.true(env, problem, "{} was accepted as a version".format(repr(bad)))
        if type(bad) == "string":
            asserts.true(env, '"{}"'.format(bad) in problem, "the problem for {} does not quote it: {}".format(repr(bad), problem))
    for good in ["0.0.0", "1.2.3", "1.2.3-pre.1", "1.2.3+b", "1.2.3-pre+b", "0.13.0"]:
        asserts.equals(env, None, version_problem(good), good)
    return unittest.end(env)

_t0_test = unittest.make(_caret_test_impl)
_t1_test = unittest.make(_caret_pre_release_test_impl)
_t2_test = unittest.make(_ordering_test_impl)
_t3_test = unittest.make(_upper_bound_test_impl)
_t4_test = unittest.make(_lower_bound_test_impl)
_t5_test = unittest.make(_ranges_test_impl)
_t6_test = unittest.make(_exact_test_impl)
_t7_test = unittest.make(_any_test_impl)
_t8_test = unittest.make(_build_metadata_test_impl)
_t9_test = unittest.make(_garbage_test_impl)

def pub_constraint_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test)
