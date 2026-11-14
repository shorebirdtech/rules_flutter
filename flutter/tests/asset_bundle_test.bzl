"""Unit tests for flutter_asset_bundle.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:asset_variants.bzl", "variant_scale")
load("//flutter/private:flutter_asset_bundle.bzl", "build_asset_manifest", "detect_dpr")

def _detect_dpr_no_variant_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, None, dpr)
    return unittest.end(env)

def _detect_dpr_2x_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/2.0x/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, 2.0, dpr)
    return unittest.end(env)

def _detect_dpr_3x_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("assets/3.0x/icon.png")
    asserts.equals(env, "assets/icon.png", base)
    asserts.equals(env, 3.0, dpr)
    return unittest.end(env)

def _detect_dpr_shorthand_test_impl(ctx):
    env = unittest.begin(ctx)
    base, dpr = detect_dpr("images/2x/photo.jpg")
    asserts.equals(env, "images/photo.jpg", base)
    asserts.equals(env, 2.0, dpr)
    return unittest.end(env)

def _detect_dpr_any_scale_test_impl(ctx):
    env = unittest.begin(ctx)
    for name, scale in {"0.75x": 0.75, "1.25x": 1.25, "5x": 5.0, "10x": 10.0, "2.x": 2.0}.items():
        base, dpr = detect_dpr("assets/%s/icon.png" % name)
        asserts.equals(env, "assets/icon.png", base, name)
        asserts.equals(env, scale, dpr, name)
    return unittest.end(env)

def _detect_dpr_only_the_immediate_parent_test_impl(ctx):
    env = unittest.begin(ctx)

    # A scale directory further up makes no variant of the file below it...
    asserts.equals(env, ("assets/2x/nested/e.png", None), detect_dpr("assets/2x/nested/e.png"))

    # ...and a file with no directory has no parent to be a variant in.
    asserts.equals(env, ("icon.png", None), detect_dpr("icon.png"))
    return unittest.end(env)

def _variant_scale_names_test_impl(ctx):
    env = unittest.begin(ctx)

    # What flutter_tools reads as a scale: `/?(\d+(\.\d*)?)x$`, unanchored at
    # the start, so a name that merely ends in a scale is one.
    for name, scale in {"2x": 2.0, "2.0x": 2.0, "1.5x": 1.5, "0.75x": 0.75, "12x": 12.0, "3.x": 3.0, "icons2x": 2.0, "a1.5x": 1.5, "1.2.5x": 2.5, ".5x": 5.0, "1.5.x": 5.0}.items():
        asserts.equals(env, scale, variant_scale(name), name)
    for name in ["", "x", "2", "2y", "x2", "a", "assets", "2xx", "2 x"]:
        asserts.equals(env, None, variant_scale(name), name)
    return unittest.end(env)

def _manifest_basic_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/icon.png"])
    asserts.true(env, "assets/icon.png" in manifest, "should have base key")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, "assets/icon.png", variants[0]["asset"])
    return unittest.end(env)

def _manifest_with_variants_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/icon.png",
        "assets/2.0x/icon.png",
        "assets/3.0x/icon.png",
    ])
    asserts.true(env, "assets/icon.png" in manifest, "should group under base path")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 3, len(variants))

    # The 1x (base) variant should be first.
    asserts.equals(env, "assets/icon.png", variants[0]["asset"])
    return unittest.end(env)

def _manifest_variant_only_test_impl(ctx):
    """A DPR variant with no 1x base should still work."""
    env = unittest.begin(ctx)
    manifest = build_asset_manifest(["assets/2.0x/icon.png"])
    asserts.true(env, "assets/icon.png" in manifest, "should use base as key")
    variants = manifest["assets/icon.png"]
    asserts.equals(env, 1, len(variants))
    asserts.equals(env, 2.0, variants[0]["dpr"])
    return unittest.end(env)

_t0_test = unittest.make(_detect_dpr_no_variant_test_impl)
_t1_test = unittest.make(_detect_dpr_2x_test_impl)
_t2_test = unittest.make(_detect_dpr_3x_test_impl)
_t3_test = unittest.make(_detect_dpr_shorthand_test_impl)
_t7_test = unittest.make(_detect_dpr_any_scale_test_impl)
_t8_test = unittest.make(_detect_dpr_only_the_immediate_parent_test_impl)
_t9_test = unittest.make(_variant_scale_names_test_impl)
_t4_test = unittest.make(_manifest_basic_test_impl)
_t5_test = unittest.make(_manifest_with_variants_test_impl)
_t6_test = unittest.make(_manifest_variant_only_test_impl)

def asset_bundle_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test)
