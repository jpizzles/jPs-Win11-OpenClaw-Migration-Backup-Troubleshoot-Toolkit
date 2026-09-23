# Changelog

v1.12.3
- ADDED a complete second post-migration connection path for attaching the new PC to an EXISTING remote OpenClaw Gateway instead of the newly restored local WSL Gateway.
- `CONNECT-WINDOWS-HUB.txt` now clearly separates Option A (restored local WSL Gateway) and Option B (existing remote Gateway over Tailscale Serve).
- Remote-Gateway instructions tell the user to check `tailscale serve status` and NOT re-run Serve when it already proxies tailnet HTTPS to `http://127.0.0.1:18789`.
- Documents Windows Hub Direct URL format: `wss://<gateway-host>.<tailnet>.ts.net`.
- Keeps shared-token retrieval interactive on the EXISTING Gateway host with `openclaw gateway auth-token --show`.
- Includes device approval and separate Windows node/CUA approval on the remote Gateway host.
- Includes shared-token rotation flow if exposed: `openclaw doctor --generate-gateway-token`, `openclaw gateway restart`, then interactive `openclaw gateway auth-token --show`.
- Final migration console now points out both restored-local and existing-remote/Tailscale choices.
- Expanded bundled README-RESTORE and README-MIGRATION with the same remote-Gateway guidance.
- Retains v1.12.2 automatic local Setup-code generation and all prior restore/pairing hardening.

v1.12.2
- ADDED automatic Windows Hub Setup-code generation at the end of a successful NEW-PC migration.
- The toolkit now runs the restored Gateway's `openclaw qr --setup-code-only --url ws://127.0.0.1:18789` command automatically and extracts the actual base64url setup payload from OpenClaw's decorated CLI output.
- Setup-code extraction validates that the candidate decodes to JSON containing both `url` and `bootstrapToken`; random update-history/decorative output is not accepted as the code.
- The migration transcript is stopped before the short-lived setup credential is minted or printed, so the bootstrap credential is not persisted into `tool-run.log`.
- The final console now prominently prints the fresh Setup code and tells the user exactly where to paste it: OpenClaw Companion -> Connection -> Setup code.
- If automatic minting fails, the final screen falls back to the exact manual WSL command.
- The code itself is not written into `CONNECT-WINDOWS-HUB.txt`, README files, or the backup package.
- Retains v1.12.1 connection guide/readmes, v1.12.0 paired-node credential migration, v1.11.x Windows Hub/PowerShell fixes, transactional restore, rollback, and verification.

v1.12.1
- ADDED explicit Windows Hub / OpenClaw Companion post-migration connection instructions.
- Migration completion now tells the user exactly what to click in the Hub: do not install another local Gateway; choose Setup code under the existing-Gateway connection options.
- Prints the exact restored WSL distro command and the exact setup-code command:
  `~/.openclaw/bin/openclaw qr --setup-code-only --url ws://127.0.0.1:18789`.
- Writes `CONNECT-WINDOWS-HUB.txt` into the external restore-log folder with the exact distro name used by that migration.
- The guide includes device approval, separate Windows node command-surface approval, Windows CUA verification, and the Direct URL+token alternative.
- Expanded both bundled `README-RESTORE.txt` and migration `README-MIGRATION.txt` with the same Windows Hub instructions.
- Clarifies stale cached node-auth warnings: they indicate an old Windows node pairing is stale, not that restored Gateway data is missing.
- No core backup/restore activation logic changed from v1.12.0.

v1.12.0
- REMOVED the Windows CUA restore prompt asking the user to paste the shared Gateway token.
- The main supported OpenClaw backup already contains the Gateway state/config/credentials. Protected secret-store values are intentionally non-revealable through normal non-interactive CLI output, so duplicating the shared Gateway bearer token into a separate plaintext file would weaken the backup rather than improve it.
- Windows node authentication is now migrated the correct way: the backup captures the complete Windows `.openclaw` state, including `state/openclaw.sqlite`, which carries nodeHost connection metadata, signed device identity, durable paired device auth tokens, and exec-approval state.
- Replaced wildcard `Compress-Archive` Windows-state capture with .NET `ZipFile.CreateFromDirectory` so hidden/system files are not silently omitted.
- Backup now records `Windows/node-identity.json` when available and verifies that `state/openclaw.sqlite` is present in the Windows state snapshot.
- NEW-PC restore automatically restores the Windows node SQLite pairing state before rebuilding the Windows CUA service.
- Destination Windows node state is safety-copied into the restore-log folder before replacement.
- After restore, `openclaw doctor --fix` reconciles legacy identity inputs and `openclaw node identity --json` verifies the restored node identity.
- The Windows CUA service first reconnects using its restored durable paired-device credential. No shared Gateway token is printed, copied to environment, or requested from the user.
- If the old paired credential is unavailable/revoked, the toolkit automatically mints a short-lived OpenClaw node bootstrap/join credential from the restored Gateway and enrolls Windows CUA with `openclaw connect --target-file ... --service --all-commands`.
- Bootstrap output is marked sensitive and is suppressed from the transcript. `--target-file` keeps the short-lived credential out of the Windows child-process command line.
- The shared Gateway token remains recoverable manually only through OpenClaw's intentional interactive command `openclaw gateway auth-token --show`; it is no longer part of the normal automated migration path.
- Existing v1.11.1 Hub download fix, v1.11.0 PowerShell 5.1 transport/end-to-end restore path, transactional state activation, rollback and verification remain intact.

v1.11.1
- FIXED noisy Windows Hub checksum 404 during new-PC setup.
- Root cause: the toolkit guessed that the upstream Windows Hub release published `OpenClawCompanion-SHA256SUMS.txt`. Current OpenClaw Windows Hub releases publish the signed installer assets but do not publish that checksum filename.
- The toolkit no longer probes a guessed checksum URL.
- It now reads the official GitHub `releases/latest` metadata, selects the exact architecture-specific installer asset, uses that asset's `browser_download_url`, and verifies the installer against GitHub's per-asset `digest` field when it is available (`sha256:<hex>`).
- Authenticode validation remains mandatory even after SHA-256 verification.
- This removes the harmless 404/warning while keeping stronger verification than the previous guessed checksum-file approach.
- No core restore logic changed from v1.11.0.

v1.11.0
- FIXED Windows PowerShell 5.1 crash caused by assigning `ProcessStartInfo.StandardInputEncoding`, which is not available in the .NET Framework ProcessStartInfo used by Windows PowerShell 5.1.
- Removed the unsupported StandardInputEncoding assignment.
- WSL Bash source is now encoded as UTF-8 without BOM and written as raw bytes to `Process.StandardInput.BaseStream`.
- StandardOutputEncoding and StandardErrorEncoding are assigned only when the runtime exposes those properties.
- Added a toolkit runtime compatibility self-test before backup/restore logic starts.
- Windows Hub/GUI installation is now best-effort and non-blocking; a GUI installer issue cannot prevent core OpenClaw backup data, Gateway, Windows CLI, or node restoration.
- Core restore still fails closed on integrity, archive verification, staging, transactional activation, and final Gateway-health failures.
- The generated WSL restore shell was executed end-to-end in the build sandbox with a synthetic OpenClaw CLI and backup. The test verified that old live state moved to rollback and restored backup data became the final ~/.openclaw state.
- A separate negative-path restore test intentionally omitted a staged asset and verified that existing live state remained untouched.
- Generated restore Bash passes `bash -n`; embedded Python activator compiles; ZIP integrity passes.
- GitHub publication intentionally withheld until a real-PC test succeeds.

v1.10.9
- FIXED immediate Windows PowerShell parser failure at `Quote-Bash` (`Unexpected token '\"'`).
- Root cause: the helper used C-style backslash escaping inside PowerShell source. PowerShell uses backtick escaping, so the helper made the entire script fail to parse before any restore code could execute.
- Removed `Quote-Bash` completely rather than patching its escaping.
- `Invoke-Wsl` now accepts a separate string-array of positional arguments. Bash source still travels over STDIN, while paths are passed after `bash -s --` as `$1`, `$2`, etc. using the existing Windows process-argument quoting function.
- Restore no longer executes `_openclaw_restore_wsl.sh` from `/mnt/c` and no longer embeds its path/archive path in shell source. The debug copy is retained in the restore-log directory, but its exact text is streamed directly over STDIN and the archive arrives as Bash `$1`.
- Added explicit UTF-8-no-BOM StandardInputEncoding to the WSL process transport.
- Added OpenClaw Windows Hub detection/install for NEW-PC prerequisite flow. The native Hub is separate from the OpenClaw CLI and provides the Windows GUI/tray/chat/Command Center/node-mode experience.
- Windows Hub download uses the official latest stable OpenClaw Windows Hub release assets, verifies the release SHA-256 when available, requires a valid Authenticode signature, and installs silently without launching the onboarding wizard.
- After migration, the toolkit tells the user to launch OpenClaw Companion and connect to the already-restored WSL Gateway rather than creating a second local Gateway.
- Retains v1.10.8 transactional restore activation, BOM-free restore shell, staging-path resolution fixes, automatic rollback, v1.10.7 distro normalization, and v1.10.6 WSL STDIN transport.

v1.10.8
- FIXED restore activation failing with a duplicated staging path such as `<stage>/<backup-name>/<backup-name>/payload/.../.openclaw`.
- Root cause: OpenClaw's staged `manifest.json` can live inside `<stage>/<backup-name>/` while an asset `archivePath` is itself prefixed with `<backup-name>/...`. The previous activator blindly resolved `manifest.parent / archivePath`, duplicating the backup directory name.
- Asset source resolution is now manifest-layout tolerant. It checks the staging root, manifest directory, manifest parent, and a de-duplicated manifest-directory-prefix form, and only accepts existing sources inside the staging tree.
- ALL staged asset sources are resolved and validated before any live destination is modified.
- Added transactional activation: every top-level replacement is fully pre-copied first; only after all copies succeed are live destinations swapped. If any swap fails, destinations already changed are automatically rolled back.
- FIXED `_openclaw_restore_wsl.sh: line 1: ﻿#!/usr/bin/env: No such file or directory`.
- Root cause: Windows PowerShell 5.1 `Set-Content -Encoding UTF8` writes a UTF-8 BOM. The restore shell is now written explicitly as UTF-8 WITHOUT BOM.
- Restore invokes the generated shell explicitly with `bash`, so execution no longer depends on shebang handling or executable-bit behavior on `/mnt/c`.
- FIXED `tee: '$HOME/openclaw-migration-restore.log': No such file or directory`.
- Root cause: PowerShell passed `'$HOME/...'` as a single-quoted literal argument. The restore invocation now omits that argument and lets the Linux script expand its own `$HOME` default internally.
- Added safe Bash argument quoting for Windows-to-WSL restore paths.
- The restore shell now creates the log parent directory before `tee`.
- Final Doctor invocation uses the canonical Linux OpenClaw binary.
- Generated restore shell passes `bash -n`, embedded Python compiles, BOM absence is checked, and a synthetic duplicated-prefix manifest test verifies the correct staged asset is found.
- Retains all v1.10.7 WSL distro identity/launch fixes, v1.10.6 STDIN shell transport, installer watchdog, verified backup/migration, fallback/resume and reset/repair behavior.

v1.10.7
- FIXED `WSL_E_DISTRO_NOT_FOUND` occurring immediately after the toolkit printed `Using WSL distro: Ubuntu-24.04`.
- Root cause addressed: `wsl.exe -l -q` output captured by Windows PowerShell 5.1 can carry invisible UTF-16 BOM/format/control characters. The distro name can LOOK exactly like `Ubuntu-24.04` in the console while still containing a hidden character that makes `wsl.exe -d <name>` fail.
- Added `Normalize-WslDistroName` to strip NUL, BOM, zero-width, Unicode control, and format characters from every WSL distro name before comparison or execution.
- Added a real launch probe (`wsl.exe -d <distro> --exec /bin/true`) before any distro is trusted.
- Added automatic distro re-selection: listed-but-non-launchable entries are ignored and every available distro is probed.
- On NEW-PC restore, if all listed distros are stale/non-launchable, the toolkit now automatically imports a fresh dedicated Ubuntu 24.04 OpenClawGateway distro instead of immediately dumping the user into manual first-run instructions.
- If `OpenClawGateway` itself is a stale/ghost registration, the importer automatically chooses a free name such as `OpenClawGateway-2` without deleting the existing distro.
- The actual Bash-STDIN transport is probed separately after distro selection.
- Direct wsl.exe paths used by path conversion and raw archive streaming now normalize the selected distro name too.
- FIXED a latent syntax defect in the generated full restore shell script caused by an earlier malformed nested `if`. The restore script was rebuilt around a canonical `OC=~/.openclaw/bin/openclaw` path and all OpenClaw restore commands now invoke that exact binary.
- The generated WSL restore shell was syntax-checked with `bash -n` during packaging.
- Retains v1.10.6 script-over-STDIN transport, canonical WSL OpenClaw/Node verification, installer watchdog, Windows installer fixes, verified backup/migration, fail-safe resume, and reset/repair.

v1.10.6
- FIXED WSL prerequisite verification returning blank `OPENCLAW_PATH` / `NODE_PATH` even though the immediately preceding canonical verification proved both binaries existed and ran successfully.
- Root cause: complex multiline Bash was still being passed as a single `bash -lc <command>` command-line argument through Windows PowerShell/wsl.exe. The logs show shell source becoming corrupted across that transport, including command-substitution/parser artifacts from earlier script text.
- Upstream transport fix: `Invoke-Wsl` no longer sends arbitrary Bash source on the wsl.exe command line. It now starts `wsl.exe -d <distro> -- bash -s` and streams the entire Bash script through redirected STDIN.
- This preserves Bash source exactly and eliminates Windows quoting/reparsing of `$`, quotes, pipes, redirects, globs, command substitutions, here-doc content, and multiline syntax.
- `Invoke-Wsl` reads stdout/stderr asynchronously to avoid pipe deadlocks during npm/OpenClaw installer output.
- WSL OpenClaw detection now uses only the canonical rootless binaries:
  - `~/.openclaw/bin/openclaw`
  - `~/.openclaw/tools/node/bin/node`
- Final prerequisite verification also uses only those canonical paths and no longer depends on `command -v`, `case`, grep path filters, or inherited PATH.
- Staged restore and post-activation verification now use the canonical WSL OpenClaw path directly.
- FIXED fallback instructions incorrectly expanding Linux `$HOME` into the Windows user profile; the generated manual commands now preserve literal `$HOME`.
- Silenced harmless Windows `Test-Path: Access is denied` noise while refreshing PATH after native Windows OpenClaw installation.
- Retains v1.10.5 detector fixes, v1.10.4 installer freeze fix/watchdog, v1.10.3 WSL/Windows runtime isolation, Windows installer fixes, deterministic WSL bootstrap, verified backup/migration, resume fallback and reset/repair.

v1.10.5
- FIXED native WSL OpenClaw detection throwing `bash: -c: syntax error near unexpected token '/mnt/*'`.
- Root cause: the previous detector used a multiline Bash `case` expression with alternation patterns (`/mnt/*|*.cmd|*.exe`) that was observed to arrive malformed through the Windows PowerShell -> wsl.exe -> `bash -lc` command transport.
- WSL OpenClaw detection is now canonical-path-first: if `~/.openclaw/bin/openclaw` exists, the toolkit uses that exact Linux binary directly.
- Removed the fragile `case` expression from WSL OpenClaw detection, prerequisite verification, and staged restore preflight.
- Windows-mounted launchers are now rejected with simple `grep` path tests instead of shell pattern alternation.
- Final prerequisite verification prefers the canonical private Node runtime at `~/.openclaw/tools/node/bin/node` before consulting PATH.
- Retains v1.10.4's post-install freeze fix: no `~/.profile` mutation, no `~/.local/bin/openclaw` symlink creation, direct canonical-binary verification, and a 15-minute installer watchdog.
- All earlier Windows installer, WSL path-isolation, deterministic WSL provisioning, backup/migration verification, fallback/resume, and reset/repair fixes remain intact.

v1.10.4
- FIXED apparent freeze immediately after a successful WSL OpenClaw installation.
- The reported run had already completed `install-cli.sh` successfully (`OpenClaw 2026.9.5`) and then stopped while the toolkit was performing a non-essential post-install `~/.local/bin` symlink / `~/.profile` mutation.
- Removed that entire post-install profile/symlink mutation. It is unnecessary because every toolkit WSL command already injects the Linux-only OpenClaw/Node PATH.
- After installer success, the toolkit now verifies the canonical runtime files directly:
  - `~/.openclaw/bin/openclaw`
  - `~/.openclaw/tools/node/bin/node`
- Directly runs both canonical binaries with `--version` before proceeding.
- Added a 15-minute installer watchdog using GNU `timeout` when available. If the actual installer hangs, the restore exits safely and writes the existing fallback/resume instructions instead of waiting forever.
- The installer verification path no longer edits shell startup files, creates symlinks, or relies on another login-shell PATH refresh.
- Retains v1.10.3 WSL/Windows PATH isolation, v1.10.2 Windows installer reliability fixes, v1.10.1 PowerShell `/dev/null` fix, deterministic WSL provisioning, verified backup/migration, fallback/resume and Option 6 repair/reset.

v1.10.3
- FIXED new-PC prerequisite verification resolving the native Windows npm OpenClaw launcher from inside WSL after the Windows installer completed.
- The failing run proved BOTH OpenClaw installations were actually successful: native WSL OpenClaw 2026.9.5 was present first, then native Windows OpenClaw 2026.9.5 installed successfully. The final WSL verification later resolved `/mnt/c/Users/.../AppData/Roaming/npm/openclaw` instead of the Linux CLI and failed with `exec: node: Permission denied`.
- Root cause: WSL appends Windows PATH entries into Linux by default. Once `%APPDATA%\npm` was added on Windows, a new WSL shell could resolve the Windows `openclaw` shim instead of the rootless Linux installation.
- `Invoke-Wsl` now runs EVERY toolkit WSL command with an explicit Linux-only PATH: `~/.openclaw/bin`, `~/.openclaw/tools/node/bin`, `~/.local/bin`, and standard Linux system directories. Windows `/mnt/c/...` PATH entries are intentionally excluded.
- WSL OpenClaw detection now rejects `/mnt/*`, `.cmd`, and `.exe` command resolutions instead of accepting a Windows shim as a valid WSL installation.
- Prerequisite verification now prints and verifies the resolved OpenClaw and Node paths; both must be native Linux paths before restore can proceed.
- The generated WSL restore script also enforces the Linux-only PATH from its first line of execution.
- Restore preflight rejects Windows shims and uses the supported rootless `install-cli.sh --runtime-only` path when Linux OpenClaw needs installation.
- Post-state-activation runtime refresh now uses the same rootless local-prefix installer and Linux-only PATH, preventing restored state from switching the Gateway runtime to Windows Node.
- Replaced the older fragile WSL profile PATH helper with a simple stable profile line.
- All v1.10.2 Windows installer fixes, v1.10.1 PowerShell `/dev/null` fixes, v1.10.0 deterministic WSL provisioning, backup/migration verification, fallback/resume, and Option 6 repair/reset remain intact.

v1.10.2
- FIXED automatic native-Windows OpenClaw installation failing with PowerShell parse errors such as `Unexpected token '32'`, `Unexpected token '79'`, etc.
- Root cause: on the affected Windows PowerShell 5.1 build, `Invoke-WebRequest(...).Content` returned installer bytes rather than a normal string. Passing that byte[] to `[scriptblock]::Create()` coerced the installer into space-separated decimal byte values (`35 32 79 112 ...`), which PowerShell then tried to parse as code.
- The toolkit no longer creates an in-memory scriptblock from `Invoke-WebRequest.Content`.
- It now downloads the official `https://openclaw.ai/install.ps1` to a temporary `.ps1` file and executes it in a clean child Windows PowerShell process with `-File ... -NoOnboard`.
- Direct `powershell -File` installation is an officially supported OpenClaw automation path and returns a non-zero exit code when installation fails.
- Adds download sanity checks to reject HTML/error pages, suspiciously small payloads, and decimal-byte-text payloads before execution.
- Adds a curl.exe fallback if Invoke-WebRequest cannot download the installer.
- Refreshes Machine/User/npm PATH after installation and checks common OpenClaw shim paths (`%APPDATA%\npm` and `%USERPROFILE%\.local\bin`) to avoid a false "not found" immediately after a successful install.
- If PATH has not propagated but a known OpenClaw launcher exists, the toolkit verifies that launcher directly.
- Retains the v1.10.1 `/dev/null` PowerShell fix, v1.10.0 deterministic WSL provisioning, backup/migration/restore checks, fail-safe resume, and Option 6 repair/reset.

v1.10.1
- FIXED new-PC restore crash at `Checking WSL systemd` with `Out-File: Could not find a part of the path 'C:\dev\null'`.
- Root cause: four Bash commands used C-style `\"` quote escaping inside PowerShell double-quoted strings. PowerShell does NOT use backslash as its quote escape, so the string terminated early and PowerShell interpreted Linux `2>/dev/null` as a Windows redirection to `C:\dev\null`.
- Rewrote the affected systemd/prerequisite shell commands as literal single-quoted PowerShell strings so Bash receives `/dev/null`, `$()`, `$c`, and shell redirections unchanged.
- Added an explicit WSL shell-routing self-test before systemd checks: `/dev/null` redirection must execute inside Linux and return `WSL_REDIRECT_OK`.
- Added `RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd` so an older verified backup package can be restored with the latest engine WITHOUT modifying the old package or invalidating its manifest.
- Added `CHECK-EXISTING-PACKAGE-NEW-PC-PREREQUISITES.cmd` for the same reason.
- The restore still verifies the selected old package's original SHA-256 manifest before any state activation.
- OpenClaw installation was not reached in the failing v1.9.1 run because the crash occurred earlier inside Ensure-WslForRestore; after this fix the flow continues from systemd -> Linux utilities -> WSL OpenClaw install -> Windows OpenClaw install.
- All v1.10.0 deterministic Ubuntu import, checksum verification, backup, migration, restore, fail-safe fallback and reset/repair features remain intact.

v1.10.0
- FIXED new-PC prerequisite/restore flow that could fail immediately after Windows accepted `wsl --install -d Ubuntu-24.04`.
- Root cause: Store-style distro installation and first-launch registration can complete asynchronously; `wsl -l` may not show the distro immediately, especially around `--no-launch`, UAC, first-run registration, or pending reboot state.
- Empty new PCs no longer depend on Microsoft Store distro registration.
- When WSL has no Linux distro, the toolkit now downloads Canonical's official Ubuntu 24.04 WSL rootfs and imports it directly as `OpenClawGateway` with `wsl --import`.
- Downloads Canonical SHA256SUMS and refuses to import the image unless SHA-256 verification succeeds.
- Supports AMD64 and ARM64 Windows.
- Stores the dedicated WSL distro under `%LOCALAPPDATA%\HatchIQ\OpenClaw\WSL`.
- Caches the verified rootfs under `%LOCALAPPDATA%\HatchIQ\OpenClaw\WSL-Cache`.
- Configures an `openclaw` Linux user and systemd without requiring Ubuntu's interactive first-launch wizard.
- Waits for distro registration after import and waits 10 seconds after termination so `/etc/wsl.conf` changes can take effect.
- If Windows WSL/Virtual Machine Platform truly requires a reboot, the restore still stops BEFORE state activation and creates the existing fallback guide + `CONTINUE-RESTORE.cmd`.
- Linux prerequisite bootstrap now also installs sudo/passwd for easier recovery.
- All v1.9.1 backup, migration, restore, launcher-path, fail-safe fallback, checksum and reset/repair features remain intact.

v1.9.1
- FIXED all packaged restore/check launcher CMD files failing with `GetFullPath(...): Illegal characters in path`.
- Root cause: `%~dp0` ends with a backslash. Passing `-RestorePackage "%~dp0"` can confuse Windows command-line quote parsing and merge later switches into the path value.
- RESTORE-THIS-BACKUP.cmd, RESTORE-ON-NEW-PC.cmd, and CHECK-NEW-PC-PREREQUISITES.cmd now `cd /d` into the package and pass `%CD%` as RestorePackage, which has no trailing package backslash.
- Resolve-PackageFolder is now defensive: if package-manifest.json exists beside the restore PS1, that directory is a trusted fallback even when the supplied RestorePackage argument is malformed.
- NewPC and PrerequisiteCheckOnly modes now route directly to the packaged restore flow even if RestorePackage is omitted/malformed.
- CONTINUE-RESTORE.cmd now uses explicit PACKAGE_DIR and RESTORE_SCRIPT environment variables for deterministic quoting.
- Added TEST-RESTORE-LAUNCHER.cmd to every Full Backup and Migration Kit. It performs a non-destructive package-path parse test before the user attempts a restore.
- All v1.9.0 prerequisite bootstrap, fallback, raw archive transfer, verification, full restore, migration, and Option 6 repair features are retained.
v1.9.0
- Added full NEW-PC prerequisite bootstrap to BOTH Full Backup and Migration Kit restore packages.
- RESTORE-ON-NEW-PC.cmd now explicitly runs in -NewPC mode.
- Added CHECK-NEW-PC-PREREQUISITES.cmd to install/check prerequisites without restoring any state.
- New-PC restore detects WSL, installed distros, systemd, required Linux utilities, WSL OpenClaw, Windows OpenClaw, and runtime availability BEFORE activation.
- If no WSL distro exists, the tool attempts to install Ubuntu-24.04 automatically, using elevation/UAC only for the Windows WSL install.
- A newly installed dedicated Ubuntu distro is initialized with a non-root `openclaw` user and systemd enabled.
- Missing Ubuntu restore utilities are installed automatically as root through `wsl.exe -u root`, avoiding Linux sudo-password prompts.
- Missing WSL OpenClaw uses the official rootless `install-cli.sh` runtime-only installer; it provisions its own supported Node runtime.
- Missing Windows OpenClaw uses the official install.ps1 installer, which can provision Node automatically.
- Added a fail-safe manual fallback: failed prerequisite automation writes RESTORE-FALLBACK-INSTRUCTIONS.txt plus CONTINUE-RESTORE.cmd OUTSIDE the immutable backup package.
- If WSL installation needs a reboot or manual first-run completion, the package is left untouched; CONTINUE-RESTORE.cmd resumes after the user finishes the prerequisite.
- Restore working shell script is now created in the external restore-log folder rather than mutating the verified backup package.
- Package checksum verification still happens before prerequisite installs and before live restore activation.
v1.8.1
- FIXED Option 6 abort on a missing `\OpenClaw Gateway` Scheduled Task.
- Root cause: Windows PowerShell 5.1 promoted schtasks.exe's expected "file/task not found" stderr into a terminating error because the script uses ErrorActionPreference=Stop.
- All Scheduled Task probes/stops/runs/deletes now go through the toolkit's protected native-command wrapper.
- Expected "task does not exist" conditions are quiet, non-fatal results.
- Windows taskkill calls in the reset path now use the same protected wrapper.
- Windows CUA rebuild no longer uses direct native OpenClaw calls for node stop/install/start; normal service-not-running messages cannot abort repair.
- Added a repair-engine self-check before destructive work to prove a missing Windows Gateway task is handled safely.
- Backup task capture and Diagnostics Scheduled Task checks received the same fix.
- Backup/migration/restore code paths otherwise remain unchanged from v1.8.0.
v1.8.0
- Added option 6: Full reset / repair / clean restart for the WSL-Gateway + Windows-CUA topology.
- Reset stops the Windows companion (if running), every OpenClaw Windows node-host process tree,
  the Windows node Scheduled Task, any accidental native-Windows Gateway process/task, and the WSL Gateway.
- Creates a best-effort verified WSL safety backup before repairs.
- Runs `openclaw doctor --fix`, then `openclaw update repair --yes --no-restart --json`.
- Reinstalls the WSL Gateway service with `openclaw gateway install --force`, starts it, and performs deep probes.
- Rebuilds Windows CUA with the supported node service path and `--all-commands`.
- Detects duplicate Windows node-host ROOT process trees, cleans/rebuilds once, and requires exactly one at final check.
- Attempts safe cleanup of stale duplicate Gateway registry records named exactly `Windows CUA` only when one connected keeper can be identified.
- Repoints tools.exec.host/tools.exec.node to the live Windows CUA after successful node describe.
- Checks required CUA commands, pending pairing, final Doctor lint, and final Gateway health.
- Security approvals are reported but never silently auto-approved.
- Old option 6 (Finalize existing package) is now option 7.
- Option 1 Full Backup now bundles full direct restore scripts too, not only Migration Kit.
- Added RESTORE-THIS-BACKUP.cmd, which automatically restores from the extracted package beside it.
- Restore, verify, and finalize transcripts are now written OUTSIDE the package so package checksums are not mutated before verification.
- Restore Gateway stop updated to protected `--force` behavior for current 2026.9.x.
v1.7.0
- FIXED final ZIP validation.
- Portable ZIP now uses includeBaseDirectory=false so package-manifest.json is at ZIP root.
- ZIP verification normalizes both slash styles and checks exact expected locations.
- Manifest is parsed from INSIDE the finished ZIP.
- The packaged OpenClaw .tar.gz byte size must match the verified source archive.
- ZIP is closed and reopened a second time before success is reported.
- Added option 6: finalize an already-created FullBackup/MigrationKit package into a Desktop ZIP without repeating the OpenClaw backup.
- Option 6 first runs package checksum verification and refuses to ZIP a bad package.

v1.6.0
- REPLACED all previous WSL->Windows archive-copy methods.
- No /mnt/c copy and no \\wsl.localhost file access are used for archive export.
- Windows launches `wsl.exe --exec /bin/cat <archive>` and copies raw stdout BaseStream directly to a Windows FileStream.
- Exact source/destination byte counts are required to match.
- WSL sha256sum must exactly match Windows Get-FileHash or the exported file is deleted and the run fails.
- Both Full Backup and Migration Kit use the same raw-binary export path.
- After package verification, the complete package is turned into ONE portable ZIP on the Windows Desktop.
- Portable ZIP is reopened and checked for package-manifest.json and the OpenClaw .tar.gz archive.
- Transcript is closed before checksumming/zipping so package hashes are stable and the log is not locked.
- Removed the now-irrelevant /mnt/c destination preflight from backup creation.

v1.5.0
- FIXED WSL->Windows export visibility issue seen on Windows 11/WSL.
- The verified archive is no longer copied into /mnt/c with Linux `cp`.
- Windows now reads the native WSL archive through \\wsl.localhost\<distro>\... and performs a binary FileStream copy itself.
- Confirms source/destination byte counts match.
- Computes SHA-256 independently in WSL and Windows and requires an exact match.
- Waits up to 30 seconds for source/destination visibility.
- Failure marker renamed to NO_BACKUP_EXPORTED.txt because OpenClaw may have successfully created and verified the WSL archive even if export fails.

v1.4.0
- FIXED false "no .tar.gz archive found" failure.
- Parses OpenClaw's exact JSON archivePath instead of scanning the Windows Payload folder.
- Creates and verifies backup on native WSL storage first.
- Copies the verified archive into the Windows Payload folder afterward.
- Confirms the archive is non-empty in WSL and again in Windows.
- Retries Windows file visibility for up to 10 seconds.
- Deletes temporary WSL staging only after the Windows export is confirmed.

v1.3.0
- FIXED Windows-to-WSL path conversion for usernames/folders containing spaces.
- Local drive paths are converted directly (C:\Users\Mick Jagger\... -> /mnt/c/Users/Mick Jagger/...).
- Added WSL destination visibility/writeability preflight BEFORE the Gateway is stopped.
- Added clearer path-mapping diagnostics.
- UNC/network targets are rejected rather than mis-mapped.

v1.2.0
- Fixed Windows PowerShell 5.1 native stderr handling.
- Fixed OpenClaw 2026.9.5 protected Gateway stop by using --force.
- Added backup command preflight.
- Added explicit failed-package markers.
- Added compact menu / console layout normalization.
- Preserved all verification and migration safety checks.
