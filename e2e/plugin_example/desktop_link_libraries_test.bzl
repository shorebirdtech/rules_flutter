"""The desktop runners link what the pub plugins' CMake builds link.

`url_launcher_windows` declares `target_link_libraries(... shlwapi.lib)` in its
`windows/CMakeLists.txt`; without it the Windows runner fails to link with
`LNK2019 unresolved external symbol __imp_UrlUnescapeA`. A plugin carries its
link libraries from its pub package as fetched, and the application collects
them, so this reads them from the real `url_launcher_windows` and
`url_launcher_linux`, in an analysis for each platform on whatever host runs
it. (An application of another desktop cannot be analysed: it AOT-compiles for
the host only.)
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_flutter//flutter:providers.bzl", "FlutterInfo")

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _libraries(env, field):
    return getattr(analysistest.target_under_test(env)[FlutterInfo], field).to_list()

def _windows_impl(ctx):
    env = analysistest.begin(ctx)
    libs = _libraries(env, "windows_plugin_libraries")
    by_package = {lib.package: lib for lib in libs}
    asserts.true(env, "url_launcher_windows" in by_package, "no url_launcher_windows in %s" % by_package.keys())
    windows = by_package["url_launcher_windows"]
    asserts.equals(env, ["shlwapi.lib"], windows.linkopts)

    # Every plugin of the app is readable: none leaves an error for the runner.
    for lib in libs:
        asserts.equals(env, [], lib.link_errors, "%s: %s" % (lib.package, lib.link_errors))
    return analysistest.end(env)

def _linux_impl(ctx):
    env = analysistest.begin(ctx)
    libs = _libraries(env, "linux_plugin_libraries")
    for lib in libs:
        asserts.equals(env, [], lib.link_errors, "%s: %s" % (lib.package, lib.link_errors))

    # url_launcher_linux links only what the runner already does.
    linux = {lib.package: lib for lib in libs}
    asserts.true(env, "url_launcher_linux" in linux, "no url_launcher_linux in %s" % linux.keys())
    asserts.equals(env, [], linux["url_launcher_linux"].linkopts)
    return analysistest.end(env)

# A plugin's desktop library is there in a build for that desktop only.
windows_link_libraries_test = analysistest.make(
    _windows_impl,
    config_settings = _platform("@rules_flutter//flutter/platforms:windows_x64"),
)

linux_link_libraries_test = analysistest.make(
    _linux_impl,
    config_settings = _platform("@rules_flutter//flutter/platforms:linux_x64"),
)
