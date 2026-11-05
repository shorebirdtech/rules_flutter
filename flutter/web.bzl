"""Flutter rules for web builds.

Two tiers of API:

    Tier 1 — flutter_web_app (self-contained, recommended):

        load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

        flutter_web_app(
            name = "my_web_app",
            deps = ["@deps//:flutter"],
            app_name = "My App",
        )

    Prerequisites: run `flutter create --platforms=web .` to generate
    the conventional `web/` directory with index.html, manifest.json,
    and icons.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:web.bzl",
            "flutter_web_bundle",
            "flutter_web_manifest_gen")

        flutter_web_manifest_gen(name = "my_manifest", app_name = "My App")

        flutter_web_bundle(
            name = "my_web_app",
            main = "lib/main.dart",
            deps = ["@deps//:flutter"],
            # A template, not a finished file: `$FLUTTER_BASE_HREF` and
            # `{{...}}` variables are substituted the way `flutter build web`
            # substitutes them, so `flutter create` output works as-is.
            index_html = "web/index.html",
            manifest_json = ":my_manifest",
            base_href = "/myapp/",
            web_defines = {"API_URL": "https://api.example.com"},
            web_assets = glob(["web/favicon.png", "web/icons/**"]),
        )

Unlike other platform rules, web rules take `main` + `deps` (Dart source)
directly — NOT a `flutter_application` target. This is because web compilation
uses dart2wasm/dart2js which consume Dart source directly, so the compilation
pipeline is structurally different from AOT platforms.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("//flutter/private:app_version.bzl", "version_arg")
load("//flutter/private:flutter_web_application.bzl", _flutter_web_bundle_rule = "flutter_web_bundle")
load("//flutter/private:flutter_web_branch.bzl", "flutter_web_branch", "web_branches_target")

# -- Gen helpers (Tier 2) -----------------------------------------------------

def flutter_web_manifest_gen(name, app_name, **kwargs):
    """Generates a manifest.json from the default Bazel template.

    Args:
        name: Target name.
        app_name: Application name substituted into the manifest fields.
        **kwargs: Additional arguments (e.g. tags, visibility).
    """
    expand_template(
        name = name,
        out = name + ".json",
        template = Label("//flutter/private/runners/web:manifest.json"),
        substitutions = {"{APP_NAME}": app_name},
        **kwargs
    )

# -- Low-level assembler (Tier 2) --------------------------------------------

def flutter_web_bundle(name, main, package_name, deps = [], srcs = [], unchecked_srcs = [], language_version = "", web_sdk = None, tags = [], testonly = None, **kwargs):
    """Builds a Flutter web application (WASM or JS) with all deployment artifacts.

    This is the low-level assembler rule. For most projects, prefer
    flutter_web_app which auto-discovers runner files.

    The bundle compiles its program once for each compiler it ships, and the
    program may differ between them: each builds for its own web platform
    (`wasm_platform`, `js_platform`). A library in `deps` picks a variant with
    a `select()` on `@rules_dart//dart/constraints:wasm` or
    `@rules_dart//dart/constraints:js` (dart2js, and DDC in a `-c dbg` build)
    in its own `deps`; a `select()` in the bundle's `deps` would see no web
    platform. See "Per-compiler code" in this repository's README. Everything the
    bundle holds once (the plugin registrant, assets and shaders) is read from
    the build it describes: the dart2wasm one for `compiler = "dart2wasm"`.

    This declares a target beside the bundle, `__<name>_branches`, which stages
    the program for each compiler: its package config and co-located sources.
    It is tagged `manual`, since only the bundle can build it for a compiler.

    Args:
        name: Target name.
        main: The entrypoint `.dart` file.
        package_name: The Dart package name of the app.
        deps: The program's Dart and Flutter libraries.
        srcs: The app's own Dart sources beside `main`.
        unchecked_srcs: More Dart sources beside `main`, whose imports are not
            checked against `deps`: files a rule wrote for the program, whose
            imports are that rule's to get right. `main` is exempt when listed
            here too.
        language_version: The app package's language version (`<major>.<minor>`).
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
            Defaults to "@flutter_web_sdk".
        tags: Tags of the bundle and of its staging target.
        testonly: Whether the bundle and its staging target are test-only.
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    if web_sdk:
        repo = web_sdk.lstrip("@")
        kwargs["_dart2wasm_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2wasm_platform.dill" % repo)
        kwargs["_dart2js_platform_dill"] = Label("@%s//:web-sdk/kernel/dart2js_platform.dill" % repo)
        kwargs["_web_sdk"] = Label("@%s//:web_sdk" % repo)

    branches = web_branches_target(name)
    flutter_web_branch(
        name = branches,
        bundle = str(native.package_relative_label(name)),
        deps = deps,
        srcs = srcs + unchecked_srcs,
        main = main,
        package_name = package_name,
        language_version = language_version,
        tags = tags + ([] if "manual" in tags else ["manual"]),
        testonly = testonly,
        visibility = ["//visibility:private"],
    )
    _flutter_web_bundle_rule(
        name = name,
        main = main,
        package_name = package_name,
        deps = deps,
        srcs = srcs + unchecked_srcs,
        unchecked_srcs = unchecked_srcs,
        language_version = language_version,
        branches = ":" + branches,
        tags = tags,
        testonly = testonly,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_web_app(
        name,
        package_name,
        deps,
        main = "lib/main.dart",
        app_name = None,
        base_href = "/",
        static_assets_url = "/",
        web_sdk = None,
        web_dir = "web",
        build_name = None,
        build_number = None,
        **kwargs):
    """Builds a Flutter web application, auto-discovering runner files.

    Discovers runner files from the conventional `web/` directory
    (as generated by `flutter create --platforms=web .`) and wires up
    index.html, manifest.json, and web assets automatically.

    Discovered as templates, and substituted the way `flutter build web`
    substitutes them — `$FLUTTER_BASE_HREF`, `$FLUTTER_STATIC_ASSETS_URL` and
    `{{...}}` variables — so raw `flutter create` output works unchanged:

        web/index.html            the page (built-in default if absent)
        web/flutter_bootstrap.js  the loader script (built-in default if absent)
        web/manifest.json         (built-in default if absent)
        web/version.json          (generated from `build_name` and
                                  `build_number` if absent; setting either
                                  with the file present is an error)

    Everything else under `web/` is copied into the bundle root verbatim.

    `web_dir` names a different directory to discover from, so one package
    can hold several web apps, each with its own page, manifest and icons:

        flutter_web_app(name = "reminders_web", web_dir = "web_apps/reminders", ...)

    This macro always uses dart2wasm + skwasm (modern defaults), and by default
    also builds a dart2js fallback for browsers that cannot run the WebAssembly,
    as `flutter build web --wasm` does. `js_fallback = False` makes the bundle
    WebAssembly only, and `flutter_bazel run -d chrome` then develops it under
    dart2wasm (no hot reload) instead of DDC, which compiles JavaScript the app
    never ships. For dart2js or canvaskit, use flutter_web_bundle directly.

    Service worker:
        By default (pwa=True), the bundle ships `flutter_service_worker.js` and
        registers it from the generated `flutter_bootstrap.js`. It adds no
        offline caching — matching `flutter build web`, which deprecated its
        caching worker in flutter/flutter#156910. The worker unregisters itself
        and reloads its clients, which is what frees visitors still holding a
        caching worker from an earlier deployment. Visitors with no existing
        worker never get one registered, so the default is free for them.

        To ship your own service worker instead, set `pwa = False` and put the
        worker in `web/` along with a `web/index.html` carrying its
        registration. With `pwa = True` both workers would claim
        `flutter_service_worker.js`, and the bundle refuses that rather than
        letting one quietly overwrite the other.

    Args:
        name: Target name.
        package_name: Dart package name (same value as `pubspec.yaml`'s `name:`).
            Required: keys the web bootstrap's `package:` URI for `main` and
            anchors codegen sibling co-location.
        deps: dart_library or flutter_library dependencies.
        main: The main .dart entry point (default "lib/main.dart").
        app_name: Application name for generated HTML/manifest (defaults to name).
        base_href: Value substituted for `$FLUTTER_BASE_HREF` in
            web/index.html (default "/"). Must start and end with "/".
        static_assets_url: Value substituted for `$FLUTTER_STATIC_ASSETS_URL`
            in web/index.html (default "/", as `flutter build web` defaults it).
            Must end with "/".
        web_sdk: Optional web SDK repo name (e.g. "@my_flutter_web_sdk").
        web_dir: The package directory the runner files are discovered in and
            whose contents are served at the bundle root (default "web").
            An `index_html`, `bootstrap_js`, `manifest_json` or `version_json`
            passed explicitly wins over the discovered file.
        build_name: The `version` of the generated version.json, as
            `flutter build web --build-name`, which `package_info_plus`
            reports. Defaults to `1.0.0`. May be a `select()`.
        build_number: The `build_number` of the generated version.json, as
            `flutter build web --build-number`. Defaults to `1`. May be a
            `select()`.
        **kwargs: Additional arguments forwarded to flutter_web_bundle
            (e.g. assets, shaders, defines, pwa, web_defines,
            keep_placeholders, tags, visibility).
            The compiler settings live there too and are forwarded the same
            way: `profile`, `js_fallback`, `wasm_browsers`, `optimization_level_js`,
            `optimization_level_wasm`, `minify_js`, `minify_wasm`,
            `strip_wasm`, `native_null_assertions`,
            `frequency_based_minification`, `enable_experiments`, `dump_info`
            and `source_maps`. Note this macro always compiles with dart2wasm,
            so `minify_wasm`, `optimization_level_wasm` and `strip_wasm` are
            live here while a `compiler = "dart2js"` bundle refuses them. The
            dart2js settings (`optimization_level_js`, `minify_js`,
            `frequency_based_minification`, `dump_info`) are refused with
            `js_fallback = False`, which leaves the JavaScript build out.
            Flutter's loader allows skwasm on Chromium only by default, so
            Firefox and Safari run the JavaScript build, or get the page's
            "could not start" message from a `js_fallback = False`
            bundle: `wasm_browsers = ["blink", "gecko", "webkit"]` allows them
            to run the WebAssembly instead.
            `extra_web_assets` is accepted here: additional web asset
            targets — typically generated files, which the `web/` glob
            cannot see — copied into the bundle root alongside the
            auto-discovered `web/` contents (the additive counterpart of
            `flutter_macos_app`'s `additional_contents`).
    """
    pwa = kwargs.pop("pwa", True)
    extra_web_assets = kwargs.pop("extra_web_assets", [])
    tags = kwargs.pop("tags", [])
    effective_app_name = app_name or name

    # Hand the discovered templates to the bundle, which substitutes them.
    # Nothing is generated here: a target of our own would only pre-substitute
    # what the bundle substitutes anyway, and would have to be told the
    # `{{...}}` variables twice to avoid failing on them.
    templates = {
        "index_html": "index.html",
        "bootstrap_js": "flutter_bootstrap.js",
        "manifest_json": "manifest.json",
        # Routed to the attr rather than left in the asset glob: the bundle
        # generates a version.json of its own, and two files claiming that
        # name is refused there.
        "version_json": "version.json",
    }
    for attr, basename in templates.items():
        path = "%s/%s" % (web_dir, basename)

        # `allow_empty`: each file is optional; absent ones are generated.
        if attr not in kwargs and native.glob([path], allow_empty = True):
            kwargs[attr] = path

    # No manifest.json given or found: generate one from the template.
    if "manifest_json" not in kwargs:
        flutter_web_manifest_gen(
            name = "__%s_manifest" % name,
            app_name = effective_app_name,
            tags = tags,
        )
        kwargs["manifest_json"] = "__%s_manifest" % name

    # Discover web assets. The files the bundle generates for itself are
    # excluded — they reach it through their own attrs, and bundling them here
    # as well is refused rather than silently resolved.
    # `allow_empty`: an app may have no web directory contents.
    web_assets = native.glob(
        [web_dir + "/**"],
        exclude = ["%s/%s" % (web_dir, b) for b in templates.values()],
        allow_empty = True,
    ) + extra_web_assets

    flutter_web_bundle(
        name = name,
        package_name = package_name,
        main = main,
        deps = deps,
        title = effective_app_name,
        base_href = base_href,
        static_assets_url = static_assets_url,
        web_assets = web_assets,
        web_dir = web_dir,
        build_name = version_arg(build_name),
        build_number = version_arg(build_number),
        web_sdk = web_sdk,
        pwa = pwa,
        tags = tags,
        **kwargs
    )
