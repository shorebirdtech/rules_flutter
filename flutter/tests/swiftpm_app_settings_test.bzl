"""Tests of how an app builds the plugins whose Package.swift decides its defines from it.

An app's aggregator reaches such plugins through `swiftpm_app_transition`,
keyed by the app's Info.plist and its `swift_package_environment`. Apps with
the same pair share one configuration of the plugins, so one build of each;
any other pair is a configuration of its own. A probe in place of a plugin
library shows which configuration it is in (the path of a file it writes) and
what the evaluation would see (the Info.plist and the environment).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//flutter/private:swiftpm_app_settings.bzl", "swift_package_environment_problems", "swiftpm_app_transition")

_SeenInfo = provider(doc = "What a probe saw.", fields = ["output", "plist", "environment"])

def _probe_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output, "")
    return [_SeenInfo(
        output = output.path,
        plist = ctx.file._info_plist.short_path,
        environment = ctx.attr._environment[BuildSettingInfo].value,
    )]

_probe = rule(
    implementation = _probe_impl,
    attrs = {
        "_info_plist": attr.label(default = "//flutter/private:swiftpm_app_info_plist", allow_single_file = True),
        "_environment": attr.label(default = "//flutter/private:swiftpm_app_environment"),
    },
)

def _app_impl(ctx):
    return [ctx.attr.probe[0][_SeenInfo]]

# An app's aggregator, as far as the transition goes.
_app = rule(
    implementation = _app_impl,
    attrs = {
        "info_plist": attr.label(allow_single_file = True),
        "swift_package_environment": attr.string_dict(),
        "probe": attr.label(cfg = swiftpm_app_transition, mandatory = True),
    },
)

def _apps_impl(_ctx):
    return [DefaultInfo()]

_apps = rule(implementation = _apps_impl, attrs = {"apps": attr.label_list(providers = [_SeenInfo])})

def _configurations_test_impl(ctx):
    env = analysistest.begin(ctx)
    seen = {}
    for app in ctx.attr.apps:
        seen[app.label.name.rsplit("__", 1)[-1]] = app[_SeenInfo]

    asserts.equals(env, "flutter/tests/swiftpm_app_settings_fixture/camera.plist", seen["camera"].plist)
    asserts.equals(env, [], seen["camera"].environment)
    asserts.equals(env, ["AUDIO_SESSION_MICROPHONE=1", "BYPASS_PERMISSION_LOCATION_ALWAYS=1"], seen["environment"].environment)
    asserts.equals(env, "flutter/private/swiftpm_no_app_Info.plist", seen["no_plist"].plist)

    # One configuration for the same Info.plist and environment.
    asserts.equals(env, seen["camera"].output, seen["camera_again"].output)

    # Another for any other.
    outputs = [seen[n].output for n in ("camera", "other_plist", "environment", "no_plist")]
    asserts.equals(env, len(outputs), len({o: None for o in outputs}), outputs)
    return analysistest.end(env)

_configurations_test = analysistest.make(
    _configurations_test_impl,
    attrs = {"apps": attr.label_list(providers = [_SeenInfo])},
)

def _environment_problems_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], swift_package_environment_problems({"AUDIO_SESSION_MICROPHONE": "1", "_X1": ""}))
    asserts.equals(env, [
        "`1X` is not an environment variable's name",
        "`A-B` is not an environment variable's name",
        "`PWD` is set by the evaluation itself",
    ], swift_package_environment_problems({"PWD": "/", "A-B": "1", "1X": "1"}))
    return unittest.end(env)

_environment_problems_test = unittest.make(_environment_problems_test_impl)

def swiftpm_app_settings_test_suite(name):
    """The tests, and the fixture targets they analyse.

    Args:
        name: Suite name.
    """
    _probe(name = name + "__probe", tags = ["manual"])
    apps = {
        "camera": {"info_plist": "swiftpm_app_settings_fixture/camera.plist"},
        "camera_again": {"info_plist": "swiftpm_app_settings_fixture/camera.plist"},
        "other_plist": {"info_plist": "swiftpm_app_settings_fixture/microphone.plist"},
        "environment": {
            "info_plist": "swiftpm_app_settings_fixture/camera.plist",
            "swift_package_environment": {"BYPASS_PERMISSION_LOCATION_ALWAYS": "1", "AUDIO_SESSION_MICROPHONE": "1"},
        },
        "no_plist": {},
    }
    for app, attrs in apps.items():
        _app(name = "{}__{}".format(name, app), probe = ":" + name + "__probe", tags = ["manual"], **attrs)
    _apps(name = name + "__apps", tags = ["manual"])
    _configurations_test(
        name = name + "_configurations",
        target_under_test = ":" + name + "__apps",
        apps = [":{}__{}".format(name, app) for app in apps],
    )
    _environment_problems_test(name = name + "_environment_problems")
    native.test_suite(
        name = name,
        tests = [
            name + "_configurations",
            name + "_environment_problems",
        ],
    )
