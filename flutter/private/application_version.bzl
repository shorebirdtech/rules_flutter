"""A bundle and its program describe one version.

`flutter build --build-name 2.1.0` gives the bundle's version fields and the
program's `appBuildName` the same value. Here the program is a
`flutter_application`, compiled once, and a platform app is built over it: each
has a `build_name` and a `build_number`. A bundle that said 2.1.0 while its code
reported 1.0.0 would ship a version nobody chose, so the application states the
version and the platform app takes it. An app may state it too, and then the
application must state the same: an application that says nothing reports the
defaults, and a bundle that says otherwise disagrees with it.
"""

load("//flutter:providers.bzl", "FlutterApplicationInputsInfo")

# For a rule that takes the version from the application it is built over.
APPLICATION_VERSION_ATTR = {
    "application": attr.label(
        doc = "The `flutter_application` the app is built over, whose " +
              "`build_name` and `build_number` the app takes when it sets none " +
              "of its own.",
        providers = [FlutterApplicationInputsInfo],
    ),
}

def application_version(label, application, build_name, build_number):
    """The version an app has: its own, else its application's.

    Args:
        label: The rule's label, for the message.
        application: The `application` target, or None for an app with none.
        build_name: The rule's `build_name`; empty is unset.
        build_number: The rule's `build_number`; empty is unset.

    Returns:
        struct(build_name, build_number), each empty when neither the app nor
        its application sets it. Fails when the app sets one the application
        does not.
    """
    if application == None:
        return struct(build_name = build_name, build_number = build_number)
    program = application[FlutterApplicationInputsInfo].inputs
    values = {}
    for attribute, mine, theirs in [
        ("build_name", build_name, program.build_name),
        ("build_number", build_number, program.build_number),
    ]:
        if mine and mine != theirs:
            fail((
                "%s: %s = %r, and the application %s it is built over has %s = %r. " +
                "The bundle's version and what the program reports as its own " +
                "would disagree. Set it on the application alone, or give both the same value."
            ) % (label, attribute, mine, application.label, attribute, theirs))
        values[attribute] = mine or theirs
    return struct(**values)
