"""Unit tests for the `flutter_pub.cycle()` declarations a build plans against.

Packages in a cycle build as one library only where a declaration says so. The
root's declarations must name packages the build builds; another module's and
rules_dart's curated ones apply only where their packages are all built.
Whether a declaration is exactly a cycle is checked when a package is planned,
by rules_dart's `dependency_cycle()`, which is tested here with the same
declarations.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:pub_graph.bzl", "cycle_error")
load("//flutter/private:pub_cycles.bzl", "DECLARE", "plan_cycles")

def _module(groups, is_root = True, name = "app"):
    return struct(
        where = "the root module" if is_root else "module `%s`" % name,
        is_root = is_root,
        groups = [sorted(g) for g in groups],
    )

def _built(*names):
    return {n: True for n in names}

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _the_root_declares_and_others_advise_test_impl(ctx):
    env = unittest.begin(ctx)

    planned = plan_cycles(
        [
            _module([["pair_b", "pair_a"]]),
            _module([["lib_x", "lib_y"], ["gone", "lib_x2"]], is_root = False, name = "lib"),
        ],
        _built("pair_a", "pair_b", "lib_x", "lib_y", "lib_x2", "dio", "dio_web_adapter"),
    )
    asserts.equals(env, None, planned.error)
    asserts.equals(env, [["pair_a", "pair_b"]], planned.declared)

    # Another module's declaration naming a package the build does not build
    # cannot apply, so it is dropped; the curated dio cycle is advised.
    asserts.equals(env, [["dio", "dio_web_adapter"], ["lib_x", "lib_y"]], planned.advisory)

    return unittest.end(env)

the_root_declares_and_others_advise_test = unittest.make(_the_root_declares_and_others_advise_test_impl)

def _a_curated_cycle_not_built_is_not_advised_test_impl(ctx):
    env = unittest.begin(ctx)

    planned = plan_cycles([_module([])], _built("dio"))
    asserts.equals(env, None, planned.error)
    asserts.equals(env, [], planned.advisory)

    return unittest.end(env)

a_curated_cycle_not_built_is_not_advised_test = unittest.make(_a_curated_cycle_not_built_is_not_advised_test_impl)

def _a_root_declaration_of_a_package_not_built_fails_test_impl(ctx):
    env = unittest.begin(ctx)

    planned = plan_cycles(
        [_module([["pair_a", "local_thing", "nowhere"]])],
        _built("pair_a"),
        {"local_thing": "maps to //local:thing with `resolve`, so a target of yours builds it"},
    )
    _mentions(env, planned.error, [
        'flutter_pub.cycle(packages = ["local_thing", "nowhere", "pair_a"])',
        "`local_thing`, which maps to //local:thing with `resolve`",
        "`nowhere`, which no `flutter_pub.from_lock()` lock lists",
        "Remove each from the declaration",
    ])
    asserts.false(env, "`pair_a`," in planned.error, planned.error)

    return unittest.end(env)

a_root_declaration_of_a_package_not_built_fails_test = unittest.make(_a_root_declaration_of_a_package_not_built_fails_test_impl)

def _a_malformed_declaration_fails_whoever_made_it_test_impl(ctx):
    env = unittest.begin(ctx)

    planned = plan_cycles(
        [_module([["a", "b"], ["b", "c"]], is_root = False, name = "lib")],
        _built("a", "b", "c"),
    )
    _mentions(env, planned.error, ["module `lib`", "`b` is in both", DECLARE])

    planned = plan_cycles([_module([["a"]])], _built("a"))
    _mentions(env, planned.error, ["the root module", "fewer than two packages"])

    return unittest.end(env)

a_malformed_declaration_fails_whoever_made_it_test = unittest.make(_a_malformed_declaration_fails_whoever_made_it_test_impl)

_GRAPH = {
    "pair_a": ["pair_b"],
    "pair_b": ["pair_a", "leaf"],
    "leaf": [],
    "ring_a": ["ring_b"],
    "ring_b": ["ring_c"],
    "ring_c": ["ring_a"],
}

def _a_cycle_is_planned_as_declared_test_impl(ctx):
    env = unittest.begin(ctx)

    # Declared by the root, or advised: planned.
    asserts.equals(env, None, cycle_error(_GRAPH, "pair_a", declared = [["pair_a", "pair_b"]], declare = DECLARE))
    asserts.equals(env, None, cycle_error(_GRAPH, "pair_b", advisory = [["pair_a", "pair_b"]], declare = DECLARE))

    # A package in no cycle needs no declaration.
    asserts.equals(env, None, cycle_error(_GRAPH, "leaf", declare = DECLARE))

    # Undeclared: the message names the cycle and the declaration to write.
    _mentions(env, cycle_error(_GRAPH, "ring_b", declare = DECLARE), [
        "`ring_a`, `ring_b` and `ring_c` depend on each other",
        'flutter_pub.cycle(packages = ["ring_a", "ring_b", "ring_c"])',
    ])

    # A root declaration of part of a cycle fails, giving the whole one.
    _mentions(env, cycle_error(_GRAPH, "ring_a", declared = [["ring_a", "ring_b"]], declare = DECLARE), [
        'flutter_pub.cycle(packages = ["ring_a", "ring_b"]), in the root module, is not a dependency cycle',
        'flutter_pub.cycle(packages = ["ring_a", "ring_b", "ring_c"])',
    ])

    # A root declaration of packages in no cycle (a stale one) fails.
    _mentions(env, cycle_error(_GRAPH, "leaf", declared = [["leaf", "pair_a"]], declare = DECLARE), [
        "`leaf` is in no cycle",
    ])

    # An advised declaration that is not exactly the cycle is inert, so the
    # cycle is undeclared.
    _mentions(env, cycle_error(_GRAPH, "ring_a", advisory = [["ring_a", "ring_b"]], declare = DECLARE), [
        "depend on each other",
    ])

    return unittest.end(env)

a_cycle_is_planned_as_declared_test = unittest.make(_a_cycle_is_planned_as_declared_test_impl)

def pub_cycles_test_suite(name):
    unittest.suite(
        name,
        the_root_declares_and_others_advise_test,
        a_curated_cycle_not_built_is_not_advised_test,
        a_root_declaration_of_a_package_not_built_fails_test,
        a_malformed_declaration_fails_whoever_made_it_test,
        a_cycle_is_planned_as_declared_test,
    )
