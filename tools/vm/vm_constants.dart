/// What rules_flutter's Windows VMs have beyond overhead's (`@overhead//vm`):
/// the auto-logon user whose console session the visual checks run in, and
/// where the VM's own tools live.
library;

/// Credentials for the auto-logon test user on Windows VMs.
///
/// These are ephemeral SPOT VMs behind GCP IAM, auto-deleted in 24h.
const windowsTestUser = 'testuser';
const windowsTestPassword = 'FlutterTest2024';

/// Where `create_windows_vm.dart` installs the VM's own tools (PsExec, the Dart
/// SDK), and where the scripts that drive the VM run them from.
const windowsToolsDir = r'C:\tools';

/// PsExec, which launches a program in the auto-logon user's console session.
const windowsPsExec = '$windowsToolsDir\\PsExec64.exe';
