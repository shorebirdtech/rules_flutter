/// Creates a SPOT Windows VM for the e2e suites and visual verification:
/// overhead's Windows VM (`@overhead//vm:create_windows_vm`) plus what
/// rules_flutter needs on it.
///
///     bazel run //tools/vm:create_windows_vm -- [vm-name] \
///         [--machine-type=e2-standard-4] [--disk-size=100GB]
///
/// Beyond overhead's:
/// - a virtual display device, for D3D rendering;
/// - `testuser`, auto-logged-on at boot so there is an interactive console
///   session for DXGI screenshots, with no RDP or tscon;
/// - Python and dxcam (the screenshot capture), PsExec (to start a program in
///   that session), and the Dart SDK `@rules_dart//dart` resolves to;
/// - Defender exclusions for the paths and processes of this repository's
///   builds.
///
/// After creation, run the e2e suites with `run_e2e.dart` or check a bundle
/// with `deploy_bundle.dart`; both wait for the startup script.
library;

import 'package:overhead_vm/create_vm.dart';

import 'hermetic_dart.dart';
import 'vm_constants.dart';

/// The Windows VM rules_flutter runs on, with the Dart SDK at [dartVersion].
WindowsVm flutterWindowsVm(String dartVersion) => WindowsVm(
  defaultName: 'flutter-windows-test',
  displayDevice: true,
  specialize: windowsSpecialize,
  startup: windowsStartup(dartVersion),
  defenderPaths: const [
    r'C:\tools',
    r'C:\android',
    r'C:\rules_dart',
    // Any user's temp directory: the SSH user's is where rules_android's
    // Python tools unpack ~2000 files per action.
    r'C:\Users\*\AppData\Local\Temp',
    // Bazel's install base and repository cache, under the SSH user's home.
    r'C:\Users\*\_bazel_*',
  ],
  defenderProcesses: const ['gen_snapshot.exe', 'aapt2.exe', 'python.exe'],
);

/// Sysprep specialize: the test user, with auto-logon registry keys so the
/// second boot creates an interactive console session (session 1).
const windowsSpecialize =
    '''
net user $windowsTestUser "$windowsTestPassword" /add /y
net localgroup Administrators $windowsTestUser /add

\$regPath = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
Set-ItemProperty -Path \$regPath -Name AutoAdminLogon -Value "1"
Set-ItemProperty -Path \$regPath -Name DefaultUserName -Value "$windowsTestUser"
Set-ItemProperty -Path \$regPath -Name DefaultPassword -Value "$windowsTestPassword"
Set-ItemProperty -Path \$regPath -Name DefaultDomainName -Value "."
''';

/// The startup steps after overhead's toolchain, as PowerShell.
String windowsStartup(String dartVersion) => _startup
    .replaceAll('TOOLS_DIR', windowsToolsDir)
    .replaceAll(
      'DART_SDK_URL',
      'https://storage.googleapis.com/dart-archive/channels/stable/release/'
          '$dartVersion/sdk/dartsdk-windows-x64-release.zip',
    )
    .replaceAll('TEST_USER', windowsTestUser);

const _startup = r'''
Install-ChocoPackage python3

# PsExec, from Sysinternals itself rather than chocolatey: the `psexec`
# package checks PsExec64.exe against a pinned hash, but Sysinternals replaces
# its files in place at unversioned URLs, so the package fails whenever a
# release lands after it was packaged. The download is checked by its
# Authenticode signature instead, which every release carries.
Step "PsExec" {
    New-Item -ItemType Directory -Force -Path TOOLS_DIR | Out-Null
    $psexec = "TOOLS_DIR\PsExec64.exe"
    curl.exe -sSL --retry 5 -o $psexec "https://live.sysinternals.com/PsExec64.exe"
    $signature = Get-AuthenticodeSignature $psexec
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
        Remove-Item -Force $psexec -ErrorAction SilentlyContinue
        throw "PsExec64.exe signature $($signature.Status) $($signature.SignerCertificate.Subject)"
    }
}

# Python packages for DXGI screen capture. The output goes to a log file: the
# GCE agent's stdout pipe breaks during a long pip install.
Step "pip install dxcam" {
    # Windows PowerShell turns a redirected native stderr line (pip's PATH
    # warning, say) into an error, which "Stop" would make fatal.
    $ErrorActionPreference = "Continue"
    $pythonDir = (Get-ChildItem C:\Python* -Directory | Select-Object -First 1).FullName
    & "$pythonDir\python.exe" -m pip install dxcam numpy Pillow opencv-python-headless *> C:\pip_install.log
}

# The Dart SDK at the version `@rules_dart//dart` resolves to, not
# `choco install dart-sdk`, which floats. curl.exe and tar.exe rather than
# Invoke-WebRequest and Expand-Archive, which are slow on an archive this size.
Step "Dart SDK" {
    $dartZip = "$env:TEMP\dartsdk.zip"
    curl.exe -sSL -o $dartZip "DART_SDK_URL"
    if (Test-Path TOOLS_DIR\dart-sdk) { Remove-Item -Recurse -Force TOOLS_DIR\dart-sdk }
    New-Item -ItemType Directory -Force -Path TOOLS_DIR | Out-Null
    tar.exe -xf $dartZip -C TOOLS_DIR
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath -notlike "*TOOLS_DIR\dart-sdk\bin*") {
        [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;TOOLS_DIR\dart-sdk\bin", "Machine")
    }
}

# The auto-logon session must be Active before the VM reports ready.
Step "wait for the TEST_USER session" {
    $ErrorActionPreference = "Continue"
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if ((query user 2>&1) -match "TEST_USER.*Active") { break }
        Start-Sleep -Seconds 5
    }
    $global:LASTEXITCODE = 0
}
''';

Future<void> main(List<String> args) async =>
    createWindowsVm(args, vm: flutterWindowsVm(await hermeticDartVersion()));
