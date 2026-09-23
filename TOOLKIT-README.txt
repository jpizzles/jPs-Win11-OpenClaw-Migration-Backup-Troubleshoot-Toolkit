OpenClaw Backup & Migration Toolkit v1.10.6
=============================================

FUNDAMENTAL WSL SCRIPT-TRANSPORT FIX
------------------------------------
The latest failure was not another failed OpenClaw installation.

Immediately before the failure, the toolkit successfully executed the canonical WSL
OpenClaw and private Node binaries. The later prerequisite script then printed empty
OPENCLAW_PATH/NODE_PATH variables.

v1.10.6 fixes the transport itself. Every toolkit WSL command is now written to a temporary
UTF-8/no-BOM, LF-only Bash file and executed with:

    wsl.exe -d <distro> -- bash --noprofile --norc <script-file>

The Bash source is no longer embedded in a Windows native command-line argument, so shell
variables, quotes, command substitution, pipes, and multiline syntax are preserved.

The same transport is used for root-level WSL setup, and a transport self-test runs before
the OpenClaw prerequisite phase.

The generated fallback guide also preserves Linux `$HOME` literally.

WSL OPENCLAW DETECTION FIX
--------------------------
The v1.10.3 log exposed a second issue before the successful OpenClaw install:

    bash: -c: line 5: syntax error near unexpected token `/mnt/*'

The detector used a Bash `case` expression with multiple glob alternatives. That expression
proved fragile through the Windows PowerShell -> wsl.exe -> bash -lc command transport.

v1.10.5 removes that syntax completely.

The toolkit now checks the canonical Linux installation first:

    ~/.openclaw/bin/openclaw
    ~/.openclaw/tools/node/bin/node

Only if those files do not exist does it consult PATH. Any result under /mnt/ or ending in
.cmd/.exe is rejected with simple grep checks.

v1.10.5 also includes the v1.10.4 fix that removed the unnecessary post-install profile/symlink
step that could appear to freeze after OpenClaw had already installed successfully.

WSL OPENCLAW POST-INSTALL FREEZE FIX
------------------------------------
The reported install already completed successfully:

    OpenClaw installed (OpenClaw 2026.9.5)

The apparent freeze happened in the toolkit's next, non-essential step that attempted to:
- create ~/.local/bin/openclaw
- edit ~/.profile

v1.10.4 removes that step completely.

Every toolkit WSL command already uses the correct Linux-only PATH, so after installation the
toolkit now verifies the canonical files directly:

    ~/.openclaw/bin/openclaw
    ~/.openclaw/tools/node/bin/node

It runs both binaries with --version and continues immediately when they pass.

The actual WSL OpenClaw installer also has a 15-minute safety watchdog when Linux `timeout`
is available. A real installer hang now stops safely and generates the normal fallback/resume
instructions instead of waiting indefinitely.

WSL / WINDOWS OPENCLAW PATH ISOLATION FIX
-----------------------------------------
A new PC can legitimately have TWO OpenClaw installations:

- Linux/WSL OpenClaw for the Gateway
- Native Windows OpenClaw for the Windows CUA node

WSL normally imports the Windows PATH. After native Windows OpenClaw is installed, WSL can
therefore see a Windows npm shim such as:

    /mnt/c/Users/<user>/AppData/Roaming/npm/openclaw

That is NOT the WSL Gateway CLI. If Bash tries to execute it, its Windows Node dependency
can fail with:

    exec: node: Permission denied

v1.10.3 isolates every toolkit WSL command from Windows PATH pollution. WSL commands now use:

    ~/.openclaw/bin
    ~/.openclaw/tools/node/bin
    ~/.local/bin
    standard Linux system directories

and explicitly reject OpenClaw/Node resolutions under /mnt/*.

The prerequisite check now proves both OpenClaw and Node resolve to native Linux paths before
restore is allowed to continue.

WINDOWS OPENCLAW INSTALLER FIX
------------------------------
The previous new-PC flow could reach the native Windows OpenClaw install and then fail with
PowerShell parse errors containing lines like:

    35 32 79 112 101 110 ...
    Unexpected token '32'

Those are decimal byte values. On the affected PowerShell 5.1 build,
Invoke-WebRequest(...).Content returned the installer as bytes; converting that byte array
directly into a ScriptBlock produced decimal numbers instead of PowerShell source.

v1.10.2 now:

1. downloads the official OpenClaw install.ps1 to a real temporary .ps1 file;
2. rejects HTML/error pages, suspiciously small downloads and decimal-byte text;
3. executes the file in a clean child PowerShell process with -NoOnboard;
4. checks the installer's real exit code;
5. refreshes Windows PATH afterward;
6. checks npm and common OpenClaw launcher paths;
7. verifies `openclaw --version` before continuing restore.

The rest of the restore still stops safely if installation cannot be verified.

POWERSHELL /dev/null RESTORE FIX
--------------------------------
The previous restore could reach Ubuntu/systemd successfully, then fail with:

    Out-File: Could not find a part of the path 'C:\dev\null'

That was a PowerShell quoting bug in the toolkit—not a WSL, Ubuntu, or OpenClaw failure.

The Bash command contained Linux redirection such as:

    2>/dev/null

but C-style `\"` quote escaping was used inside a PowerShell string. Windows PowerShell 5.1
does not use backslash to escape quotes, so it parsed part of the Bash command itself and
tried to redirect to C:\dev\null.

v1.10.1 uses literal PowerShell strings for those Bash commands and adds a WSL redirection
self-test before the systemd check.

RESTORING AN ALREADY-CREATED OLD BACKUP
----------------------------------------
You do NOT need to regenerate your v1.9.1 backup.

Extract this v1.10.1 toolkit separately and run:

    RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd

Select the existing extracted backup folder when prompted. The v1.10.1 engine verifies the
old package's original manifest/checksums and restores it without modifying that package.

To test prerequisites only:

    CHECK-EXISTING-PACKAGE-NEW-PC-PREREQUISITES.cmd

NEW-PC WSL PROVISIONING FIX
---------------------------
When WSL is installed but NO Linux distro exists, this version does not rely on Microsoft
Store/first-launch registration. It downloads Canonical's official Ubuntu 24.04 WSL rootfs,
verifies it against Canonical's published SHA-256, and imports it directly as:

    OpenClawGateway

using `wsl --import`.

The toolkit then creates the `openclaw` user, enables systemd, restarts WSL, verifies the
default user, installs Linux prerequisites/OpenClaw as needed, and continues the restore.

If Windows genuinely needs a reboot to finish WSL/Virtual Machine Platform activation, the
toolkit stops before touching restored OpenClaw state and creates the normal fallback guide
plus CONTINUE-RESTORE.cmd.

RESTORE-LAUNCHER PATH FIX
-------------------------
v1.9.0 generated CMD files passed:

    -RestorePackage "%~dp0"

`%~dp0` ends with a backslash. On Windows command-line parsing, that trailing backslash can
interfere with the closing quote and cause later switches such as -NewPC to become part of
the path string. PowerShell then throws:

    GetFullPath: Illegal characters in path.

v1.9.1 fixes every generated restore/check CMD. The launcher now:

    cd /d "%~dp0"
    set "PACKAGE_DIR=%CD%"
    ... -RestorePackage "%PACKAGE_DIR%"

The PowerShell restore code also independently detects package-manifest.json beside itself,
so even a malformed external RestorePackage argument cannot break a package-local restore.

Every new backup/migration package also includes:

    TEST-RESTORE-LAUNCHER.cmd

That test does NOT install, restore, or modify OpenClaw. It only proves that Windows can
resolve the package path and see package-manifest.json correctly.

NEW-PC SELF-BOOTSTRAPPING RESTORE
---------------------------------
Every Full Backup and Migration Kit now contains:

  RESTORE-THIS-BACKUP.cmd
  RESTORE-ON-NEW-PC.cmd
  CHECK-NEW-PC-PREREQUISITES.cmd
  RESTORE-THIS-BACKUP.ps1
  RESTORE-ON-NEW-PC.ps1
  README-RESTORE.txt

For a brand-new Windows 11 PC, run RESTORE-ON-NEW-PC.cmd.

Before changing live OpenClaw state it checks and, where possible, automatically installs:
- WSL / WSL2
- Ubuntu 24.04 when no Linux distro exists
- systemd configuration
- curl, Python 3, tar/gzip/coreutils, CA certificates and dbus-x11
- OpenClaw inside WSL using the rootless local-prefix installer
- the supported local Node runtime used by that installer
- native Windows OpenClaw using the official PowerShell installer
- Windows Node runtime when the official installer needs it

If Windows needs a reboot, a distro needs first-run completion, internet/package installation
fails, or an installer otherwise cannot finish automatically, the tool stops BEFORE restoring
live state and creates:

  Documents\OpenClaw-Restore-Logs\...\RESTORE-FALLBACK-INSTRUCTIONS.txt
  Documents\OpenClaw-Restore-Logs\...\CONTINUE-RESTORE.cmd

Complete the listed manual prerequisite, then run CONTINUE-RESTORE.cmd. The tool rechecks
everything and continues the automated file/state placement and service/node rebuild.

CHECK-NEW-PC-PREREQUISITES.cmd performs this bootstrap/readiness pass without activating
the backup, so a new PC can be prepared before the actual migration.

OPTION 6 HOTFIX
---------------
The v1.8.0 repair could stop after:

    Checking for accidental native-Windows Gateway instances
    ERROR: The system cannot find the file specified.

That error actually means the unwanted Windows Gateway Scheduled Task DOES NOT EXIST,
which is the desired state for this WSL-Gateway topology.

PowerShell 5.1 was treating schtasks.exe stderr as a terminating script error.
v1.8.1 routes every Scheduled Task probe/stop/run/delete in the affected paths through
the protected native-command wrapper. Missing tasks and already-stopped services are
now normal non-fatal conditions.

At the beginning of Option 6, a self-check explicitly tests this behavior before the
repair starts changing services/processes.

All v1.8.0 backup, migration, direct restore, raw WSL-to-Windows transfer, checksum,
and portable ZIP functionality is retained.

NEW OPTION 6 - FULL RESET / REPAIR / CLEAN RESTART
--------------------------------------------------
Designed for this installation topology:
- WSL: the one real OpenClaw Gateway (systemd user service)
- Windows 11: the Windows CUA node/companion
- No native Windows Gateway

The repair routine:
1. Captures diagnostics and any running Windows companion path.
2. Stops the companion.
3. Stops the Windows OpenClaw Node Scheduled Task/service.
4. Kills every OpenClaw `node run` process TREE and verifies none remain.
5. Removes a competing native-Windows Gateway task/process if one exists.
6. Fully stops/kills the WSL Gateway systemd unit.
7. Attempts a verified pre-repair safety backup inside WSL.
8. Runs Doctor repair and update/plugin repair.
9. Reinstalls the intended WSL Gateway service definition and verifies a deep health probe.
10. Rebuilds Windows CUA cleanly with --all-commands.
11. Requires exactly ONE Windows node-host ROOT process tree.
12. Checks the Gateway registry for stale duplicate entries named `Windows CUA`;
    stale copies are only auto-removed when exactly one connected keeper is unambiguous.
13. Repairs the exec-node binding to Windows CUA.
14. Checks computer.act, screen.snapshot, system.run, pairing queues, Doctor lint, and Gateway health.
15. Restarts the Windows companion if it was running.

OpenClaw security approval prompts are never silently bypassed.

FULL RESTORE IS NOW IN OPTION 1 TOO
-----------------------------------
Every Full Backup and every Migration Kit now contains:
- RESTORE-THIS-BACKUP.cmd
- RESTORE-THIS-BACKUP.ps1
- RESTORE-ON-NEW-PC.cmd
- RESTORE-ON-NEW-PC.ps1
- README-RESTORE.txt

After extracting a backup ZIP, double-click RESTORE-THIS-BACKUP.cmd.
It automatically uses that package and runs the verified staged restore.

ZIP FINALIZATION FIX
--------------------
The backup/migration data path from v1.6 is retained:
- OpenClaw creates and verifies the archive in WSL.
- wsl.exe streams raw archive bytes into a Windows FileStream.
- Windows and WSL byte counts and SHA-256 must match.

v1.7 changes the FINAL portable ZIP stage:
- package-manifest.json is written directly at ZIP root.
- Payload/<OpenClaw backup>.tar.gz is required.
- the manifest is parsed again from inside the completed ZIP.
- the archive byte size inside the ZIP must match the verified source.
- the ZIP is closed and reopened again before success is declared.

NEW OPTION 6
------------
If the OpenClaw package folder already completed successfully and only the final ZIP step failed,
choose option 6. It verifies the existing package and creates the Desktop ZIP without rerunning
the Gateway stop/backup process.

IMPORTANT COPY ARCHITECTURE CHANGE
----------------------------------
This release no longer tries to copy the OpenClaw archive using Linux `cp` into /mnt/c,
and it no longer depends on Windows being able to browse \\wsl.localhost.

The verified WSL archive is exported as raw bytes like this:

    wsl.exe -d <distro> --exec /bin/cat <verified-archive>
         -> raw StandardOutput.BaseStream
         -> Windows FileStream
         -> Payload\<archive>.tar.gz

The tool then requires:
1. exact byte-size match between WSL and Windows,
2. exact SHA-256 match between WSL sha256sum and Windows Get-FileHash,
3. package-manifest checksum verification,
4. a final portable ZIP on your Windows Desktop,
5. successful reopening of that ZIP with both package-manifest.json and the .tar.gz present.

Both Full Backup and Migration Kit use this same transfer code.

Migration
---------
Option 2 creates a complete migration package and then creates ONE portable ZIP on the Desktop.
Copy that ZIP to the new Windows 11 machine, extract it, and run RESTORE-ON-NEW-PC.cmd.

Fixes in v1.5.0
-----------------
- Fixes the WSL/Windows visibility problem where WSL showed the copied tar.gz under /mnt/c
  but Windows PowerShell could not see the same file.
- Windows now copies the verified archive directly from:
    \\wsl.localhost\<WSL-DISTRO>\home\...
  into the Windows Payload folder.
- Uses binary FileStream copying (no text redirection).
- Requires exact byte-size match after the copy.
- Requires SHA-256 from WSL to exactly match Windows Get-FileHash.
- Only deletes the WSL staging copy after all checks pass.

Fixes in v1.4.0
-----------------
- Fixes the false "Backup command returned success but no .tar.gz archive was found" error.
- Uses OpenClaw's exact JSON archivePath instead of guessing by directory scan.
- Creates and verifies the backup on native WSL storage first.
- Copies the already-verified archive to the Windows Payload folder afterward.
- Confirms the exported file exists and is non-empty before reporting success.

Fixes in v1.3.0
-----------------
- Fixes "Unable to convert Windows path to WSL path" for paths containing spaces.
- Tests the mapped Payload directory from WSL before stopping the Gateway.
- Uses direct /mnt/<drive>/ conversion for normal local Windows drives.

Fixes in v1.2.0
-----------------
- Fixes the empty Payload bug seen with OpenClaw 2026.9.5.
  OpenClaw now protects non-interactive Gateway stops; the tool uses
  `openclaw gateway stop --force` and handles native stderr safely.
- Adds a backup-command preflight before stopping anything.
- Failed runs are explicitly marked with BACKUP_FAILED.txt and
  Payload\NO_BACKUP_CREATED.txt instead of leaving a misleading empty Payload.
- Cleans up the double-click menu and normalizes console width/height.
- Keeps the independent archive verification, SHA-256 package self-check,
  Gateway restart/health verification, Windows node snapshot, and migration restore logic.

OpenClaw Backup & Migration Toolkit v1.1.0
==========================================

What this is
------------
A double-click Windows toolkit for a Windows + WSL2 OpenClaw setup.

Files
-----
- OpenClaw-Backup-Migrate.cmd   -> Double-click this.
- OpenClaw-Backup-Migrate.ps1   -> Main PowerShell tool.

Menu
----
1. Full backup of everything
   - Stops the WSL Gateway for a consistent migration-grade snapshot.
   - Runs the supported `openclaw backup create --verify` flow.
   - Runs a second independent `openclaw backup verify`.
   - Captures Windows-side `.openclaw` files and the OpenClaw Node Scheduled Task.
   - Builds SHA-256 checksums and self-verifies the package.
   - Restarts the WSL Gateway and performs a deep health probe.

2. Create migration kit
   - Does everything in option 1.
   - Bundles this restore tool inside the migration folder.
   - Copy the entire migration folder to the new PC and run RESTORE-ON-NEW-PC.cmd.

3. Restore / migrate onto this computer
   - Validates every outer package checksum before making changes.
   - Ensures WSL exists.
   - Installs latest stable OpenClaw in WSL if OpenClaw is missing.
   - Verifies the OpenClaw archive using OpenClaw itself.
   - Creates a pre-restore safety backup when possible.
   - Restores to staging (OpenClaw never overwrites live state directly).
   - Reads OpenClaw's manifest.json and maps old-home paths to the new WSL user's home.
   - Moves existing destination assets to a rollback directory before activation.
   - Refreshes latest stable OpenClaw runtime after activation.
   - Runs database preflight, Doctor, plugin/update repair, Gateway install/start, and deep health checks.
   - Installs Windows OpenClaw if missing.
   - Enables CUA, checks driver artifacts, and attempts to recreate the Windows CUA node service using:
       --display-name "Windows CUA" --all-commands

4. Verify a package
   - Checks SHA-256 hashes.
   - If OpenClaw is installed in WSL, also runs `openclaw backup verify`.

5. Diagnostics
   - Read-only WSL Gateway/Doctor/node checks plus Windows node process/task inspection.

Security
--------
These backups can contain:
- OAuth credentials
- provider/API credentials
- channel credentials
- device pairing state
- sessions and conversation history
- workspaces and memory

Treat a migration folder like a password vault. Prefer an encrypted external disk or other protected storage.

Important restore behavior
--------------------------
The Windows\windows-openclaw-state.zip snapshot is kept for complete recovery/reference,
but the migration flow deliberately does NOT blindly overwrite the destination Windows
`.openclaw` directory with it. Windows node identities, launcher paths, and copied Gateway
tokens are machine-specific and can produce stale pairings/token mismatches on a new PC.
Instead, the migration tool recreates the Windows CUA node service against the restored Gateway.

The WSL OpenClaw archive is the authoritative full state/workspace migration artifact.

OpenClaw documentation used when building this tool
---------------------------------------------------
- Backups: https://docs.openclaw.ai/install/backups
- Migration: https://docs.openclaw.ai/install/migrating
- Install: https://docs.openclaw.ai/install
- Windows: https://docs.openclaw.ai/platforms/windows
- Node service: https://docs.openclaw.ai/cli/node


v1.1.0 fix
----------
- Fixed Windows PowerShell 5.1 treating OpenClaw stderr as a terminating error.
- Uses `openclaw gateway stop --force` when stopping the WSL Gateway from the non-interactive backup process.
- Falls back to `systemctl --user stop` if OpenClaw service stop itself fails.
- Explicitly checks that Payload contains a non-empty verified .tar.gz before declaring success.
