"""Builds each example extension twice: signed ad hoc and signed by a team."""

load("@rules_apple//apple:macos.bzl", "macos_extension")
load("@rules_flutter//tools/e2e_testing:signing_twin.bzl", "signing_twin")

def example_macos_extension(name, **kwargs):
    """A `macos_extension` as `name` and its team-signed twin as `name + "_team"`.

    `name` has no profile, so rules_apple signs it ad hoc, with the `group.`
    App Group. `name_team` is signed with `//:device_profile` and carries the
    team-prefixed group from `//:device_app_group`, the flags that stand for the
    developer's `//device` files. rules_apple signs each extension in
    its own target, so the app's profile does not reach it: an extension
    without its own is signed ad hoc, has no team, and loses its App Group.

    Args:
        name: The ad hoc target's name.
        **kwargs: Forwarded to both `macos_extension` targets.
    """
    signing_twin(
        macos_extension,
        name,
        "_team",
        common = dict(
            tags = ["manual"],
            target_compatible_with = ["@platforms//os:macos"],
            # rules_apple's default is no version at all, and an extension's
            # version must match the app's, so the app takes this one too.
            version = "//:app_version",
            visibility = ["//:__pkg__"],
        ),
        base = dict(entitlements = ":extension_entitlements"),
        twin = dict(
            entitlements = ":extension_entitlements_team",
            provisioning_profile = "//:device_profile",
        ),
        overrides = kwargs,
    )
