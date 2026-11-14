"""A test of the glyphs a web bundle's shipped icon font kept."""

load("@rules_dart//dart:defs.bzl", "dart_test")

def icon_font_test(name, bundle, keeps, lacks = []):
    """Checks the character map of the MaterialIcons font `bundle` ships.

    Args:
        name: Prefix of the test's name; the test is `<name>_test`.
        bundle: Name of the `flutter_web_app` in this package.
        keeps: Code points, in hex, the font must have a glyph for.
        lacks: Code points, in hex, it must not: proof the font was subset.
    """
    dart_test(
        name = name + "_test",
        size = "small",
        args = [
            "--bundle=web_interop/%s_web" % bundle,
            "--keeps=" + ",".join(keeps),
            "--lacks=" + ",".join(lacks),
        ],
        data = [":" + bundle],
        main = "test/verify_icon_font_test.dart",
        deps = ["@rules_flutter//tools/e2e_testing"],
    )
