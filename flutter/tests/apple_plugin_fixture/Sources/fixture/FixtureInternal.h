// Private: uses NS_ENUM without importing Foundation, as permission_handler_apple's
// PermissionHandlerEnums.h does, so it only compiles after another import.

#ifndef FIXTURE_FEATURE
    #define FIXTURE_FEATURE 0
#endif

typedef NS_ENUM(int, FixtureState) {
    FixtureStateOff = 0,
    FixtureStateOn,
};
