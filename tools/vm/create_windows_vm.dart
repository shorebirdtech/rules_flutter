/// Creates a preemptible Windows VM for Flutter app visual verification.
///
/// Usage: dart run tools/vm/create_windows_vm.dart [vm-name]
///            [--machine-type=e2-standard-4] [--disk-size=100GB]
///
/// The VM is created with:
/// - Windows Server 2022
/// - Preemptible (low cost, auto-deleted after 24h)
/// - Virtual display device (--enable-display-device) for D3D rendering
/// - SSH enabled via google-compute-engine-ssh
/// - Auto-logon: testuser is created with an interactive console session
///   at boot — no RDP or tscon needed for DXGI screenshots
/// - Visual C++ Build Tools, Dart SDK, Git, Bazel, Python + dxcam installed
///
/// After creation, deploy and verify entirely over SSH:
///   dart run tools/vm/deploy_bundle.dart <vm-name> <bundle_path> --windows
library;

import 'dart:io';

import 'gcloud.dart';
import 'hermetic_dart.dart';

const _defaultName = 'flutter-windows-test';
const _defaultMachineType = 'e2-standard-4';
const _defaultDiskSize = '100GB';
const _imageFamily = 'windows-2022';
const _imageProject = 'windows-cloud';

/// Sysprep specialize script — runs once on first boot before GCP auto-reboots.
///
/// Creates the test user with auto-logon registry keys so the second boot
/// creates an interactive console session (session 1) automatically — no RDP needed.
String get _specializeScript =>
    '''
# Install SSH via googet (must happen during sysprep).
googet -noconfirm=true install google-compute-engine-ssh

# Create test user with known password.
net user $windowsTestUser "$windowsTestPassword" /add /y
net localgroup Administrators $windowsTestUser /add

# Set auto-logon registry keys so the user gets a console session at boot.
\$regPath = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
Set-ItemProperty -Path \$regPath -Name AutoAdminLogon -Value "1"
Set-ItemProperty -Path \$regPath -Name DefaultUserName -Value "$windowsTestUser"
Set-ItemProperty -Path \$regPath -Name DefaultPassword -Value "$windowsTestPassword"
Set-ItemProperty -Path \$regPath -Name DefaultDomainName -Value "."
''';

/// PowerShell startup script — runs on every boot.
///
/// Installs tools, then waits for the auto-logon session to be Active
/// before signalling completion.
const _startupScript = r'''
# Keep Defender's real-time scan off the build trees. A Bazel build writes tens
# of thousands of small files, and scanning them takes most of a core, which a
# timing measurement here would then include. Set before anything builds.
Add-MpPreference -ExclusionPath 'C:\b','C:\rf','C:\rules_dart','C:\android','TOOLS_DIR','C:\temp','C:\Users\testuser\AppData\Local\Temp','C:\Windows\Temp'
Add-MpPreference -ExclusionProcess 'java.exe','bazel.exe','dart.exe','cl.exe','link.exe','gen_snapshot.exe','aapt2.exe'

# Install Chocolatey (package manager).
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Install prerequisites.
choco install -y git --params "/GitAndUnixToolsOnPATH"
choco install -y bazelisk
choco install -y vcredist140
choco install -y visualstudio2022buildtools --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
choco install -y python3

# PsExec, from Sysinternals itself rather than chocolatey: the `psexec`
# package downloads PSTools.zip and checks PsExec64.exe against a pinned hash,
# but Sysinternals replaces its files in place at unversioned URLs, so the
# package fails to install whenever a release lands after it was packaged.
# Pinning a hash here would fail the same way, so the download is checked by
# its Authenticode signature instead, which every release carries. A file that
# is not Microsoft-signed is deleted and the startup marker says why.
New-Item -ItemType Directory -Force -Path TOOLS_DIR | Out-Null
$psexec = "TOOLS_DIR\PsExec64.exe"
curl.exe -sSL --retry 5 -o $psexec "https://live.sysinternals.com/PsExec64.exe"
$signature = Get-AuthenticodeSignature $psexec
if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
    Remove-Item -Force $psexec -ErrorAction SilentlyContinue
    New-Item -Path C:\startup_complete.txt -Value "STARTUP_FAILED: PsExec64.exe signature $($signature.Status) $($signature.SignerCertificate.Subject)" -Force
    exit 1
}

# Install Python packages for DXGI screen capture.
# Redirect output to a log file — the GCE agent's stdout pipe breaks during
# long pip installs, causing "Pipe to stdout was broken" errors.
$pythonDir = (Get-ChildItem C:\Python* -Directory | Select-Object -First 1).FullName
if ($pythonDir) {
    & "$pythonDir\python.exe" -m pip install dxcam numpy Pillow opencv-python-headless > C:\pip_install.log 2>&1
}

# Dart SDK. The official zip at the version `@rules_dart//dart` resolves to,
# not `choco install dart-sdk`, which floats to whatever chocolatey last
# packaged and so cannot match the build. Same URL shape and same source of
# truth as create_linux_vm.dart — see hermetic_dart.dart. Kept at
# TOOLS_DIR\dart-sdk so the path everything else expects is unchanged.
# curl.exe and tar.exe, both shipped with Windows Server 2022, rather than
# Invoke-WebRequest and Expand-Archive: Invoke-WebRequest's progress bar
# throttles a download this size (~350MB) by an order of magnitude unless
# $ProgressPreference is silenced, and Expand-Archive is slow on an archive
# this size for its own reasons. It also matches what create_linux_vm.dart
# does, for one less difference between them.
$dartZip = "$env:TEMP\dartsdk.zip"
curl.exe -sSL -o $dartZip "DART_SDK_URL"
if (Test-Path TOOLS_DIR\dart-sdk) { Remove-Item -Recurse -Force TOOLS_DIR\dart-sdk }
New-Item -ItemType Directory -Force -Path TOOLS_DIR | Out-Null
tar.exe -xf $dartZip -C TOOLS_DIR
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*TOOLS_DIR\dart-sdk\bin*") {
    [System.Environment]::SetEnvironmentVariable("Path", "$machinePath;TOOLS_DIR\dart-sdk\bin", "Machine")
}

# Set BAZEL_VC so Bazel finds MSVC.
[System.Environment]::SetEnvironmentVariable("BAZEL_VC", "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC", "Machine")

# Disable Server Manager auto-start (blocks the desktop).
schtasks /Change /TN "\Microsoft\Windows\Server Manager\ServerManager" /DISABLE

# Wait for testuser auto-logon session to become Active.
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    $sessions = query user 2>&1
    if ($sessions -match "testuser.*Active") {
        break
    }
    Start-Sleep -Seconds 5
}

# Signal completion.
New-Item -Path C:\startup_complete.txt -Value "STARTUP_COMPLETE" -Force
''';

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final prefix = '--$name=';
    final given = args.where((a) => a.startsWith(prefix));
    return given.isEmpty ? fallback : given.last.substring(prefix.length);
  }

  final positional = args.where((a) => !a.startsWith('--')).toList();
  final vmName = positional.isNotEmpty ? positional.first : _defaultName;
  final machineType = option('machine-type', _defaultMachineType);
  final diskSize = option('disk-size', _defaultDiskSize);
  final project = await getProject();
  final zone = await getZone();
  final dartVersion = await hermeticDartVersion();

  print('Creating Windows VM: $vmName');
  print('  Project: $project');
  print('  Zone: $zone');
  print('  Machine type: $machineType');
  print('  Dart SDK: $dartVersion (from @rules_dart//dart)');
  print('  Image: $_imageFamily ($_imageProject)');
  print('  Preemptible: yes');
  print('  SSH: enabled');
  print('  Virtual display: enabled');
  print('');

  // Write scripts to temp files to avoid shell escaping issues.
  final tmpDir = Directory.systemTemp.createTempSync('win_vm_');
  final tmpSpecialize = File('${tmpDir.path}/specialize.ps1');
  final tmpStartup = File('${tmpDir.path}/startup.ps1');
  tmpSpecialize.writeAsStringSync(_specializeScript);
  tmpStartup.writeAsStringSync(
    _startupScript
        .replaceAll('TOOLS_DIR', windowsToolsDir)
        .replaceAll(
          'DART_SDK_URL',
          'https://storage.googleapis.com/dart-archive/channels/stable/release/'
              '$dartVersion/sdk/dartsdk-windows-x64-release.zip',
        ),
  );

  try {
    await gcloud([
      'compute',
      'instances',
      'create',
      vmName,
      '--machine-type=$machineType',
      '--image-family=$_imageFamily',
      '--image-project=$_imageProject',
      '--provisioning-model=SPOT',
      '--instance-termination-action=DELETE',
      // Virtual display device — required for D3D rendering and DXGI capture.
      '--enable-display-device',
      '--metadata=enable-windows-ssh=TRUE',
      '--metadata-from-file=sysprep-specialize-script-ps1=${tmpSpecialize.path},windows-startup-script-ps1=${tmpStartup.path}',
      '--scopes=default',
      // SSD, not the default standard disk: a Bazel build here is tens of
      // thousands of small file writes and deletes, and rules_android's Python
      // tools extract ~2000 files into %TEMP% on every run. On a standard disk
      // those actions took minutes each and a build looked hung (measured: the
      // same android_example build, 60+ min unfinished vs 9 min).
      '--boot-disk-type=pd-ssd',
      '--boot-disk-size=$diskSize',
    ]);
  } finally {
    tmpDir.deleteSync(recursive: true);
  }

  print('');
  print('VM created. Waiting for SSH ...');
  await waitForSsh(vmName, timeout: const Duration(minutes: 10));

  print('');
  print('Windows VM created: $vmName');
  print('');
  print('The startup script is installing tools (Git, Dart, Bazel, MSVC,');
  print('Python, dxcam, PsExec). This takes ~15 minutes.');
  print('');
  print('The deploy script checks readiness automatically. Just run:');
  print(
    '  dart run tools/vm/deploy_bundle.dart $vmName <bundle_path> --windows',
  );
  print('');
  print('Delete when done:');
  print('  gcloud compute instances delete $vmName --quiet');
}
