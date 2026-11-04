"""Builds each example extension twice: for the simulator and for a device."""

load("@rules_apple//apple:ios.bzl", "ios_extension")
load("@rules_flutter//flutter:ios.bzl", "IOS_MINIMUM_OS_VERSION")
load("@rules_flutter//tools/e2e_testing:signing_twin.bzl", "signing_twin")

def example_ios_extension(name, **kwargs):
    """An `ios_extension` as `name` and its device twin as `name + "_device"`.

    `name` carries the App Group and is unsigned, which is all a simulator
    needs. `name_device` is signed with `//:device_profile`, the developer's
    team wildcard profile, and drops the App Group: a wildcard profile cannot
    grant one, and a device build that asks for an entitlement its profile
    lacks fails. With an explicit App ID and profile per bundle id, which
    register the group, the device twin would keep `entitlements` and name its
    own profile.

    Args:
        name: The simulator target's name.
        **kwargs: Forwarded to both `ios_extension` targets.
    """
    signing_twin(
        ios_extension,
        name,
        "_device",
        common = dict(
            families = ["iphone"],
            minimum_os_version = IOS_MINIMUM_OS_VERSION,
            # rules_apple's default is no version at all, and an extension's
            # version must match the app's: 1.0, flutter_ios_app's default.
            version = "//:app_version",
            visibility = ["//:__pkg__"],
            tags = ["manual"],
        ),
        base = dict(entitlements = ":AppGroup.entitlements"),
        twin = dict(provisioning_profile = "//:device_profile"),
        overrides = kwargs,
    )
