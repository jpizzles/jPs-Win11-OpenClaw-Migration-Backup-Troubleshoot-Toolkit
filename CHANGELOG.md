# Changelog

## v1.10.6

- Fundamental WSL command-transport fix: Bash programs are no longer passed as multiline `bash -lc <string>` arguments through Windows PowerShell 5.1 / `wsl.exe`.
- The latest failing run proved the installer itself was healthy: `~/.openclaw/bin/openclaw` and `~/.openclaw/tools/node/bin/node` both executed successfully immediately after installation. A later prerequisite check then lost its Bash variables (`OPENCLAW_PATH=` / `NODE_PATH=`), isolating the failure to command transport rather than OpenClaw.
- `Invoke-Wsl` now writes Bash source to a temporary UTF-8/no-BOM, LF-only `.sh` file and invokes `bash --noprofile --norc <script>` as separate native arguments.
- Added `Invoke-WslRoot` using the same script-file transport for root-level WSL initialization, systemd configuration and apt prerequisite installation.
- Removed remaining complex toolkit `bash -lc` calls from the new-PC prerequisite path.
- Added a pre-install WSL transport self-test for multiline variables, quoting, spaces and command substitution.
- Final prerequisite verification directly executes the canonical rootless runtime files `~/.openclaw/bin/openclaw` and `~/.openclaw/tools/node/bin/node`.
- Staged restore preflight and post-restore runtime refresh use the same canonical local-prefix runtime.
- Fixed generated fallback instructions incorrectly expanding Linux `$HOME` into a Windows user path.
- Suppressed misleading Windows `Test-Path: Access is denied` transcript noise during PATH refresh by using non-throwing .NET existence checks.
- Retains all backup/migration verification, deterministic new-PC WSL provisioning, installer watchdogs, resume fallback and Option 6 reset/repair behavior.

## v1.10.5

- Fixed WSL OpenClaw detector syntax error.
- Prefer canonical Linux OpenClaw and private Node binaries.
- Retain post-install freeze fix and watchdog.

## v1.10.4

- Fixed apparent freeze immediately after a successful WSL OpenClaw installation.
- Removed the non-essential `~/.local/bin` symlink / `~/.profile` mutation.
- Verifies `~/.openclaw/bin/openclaw` and `~/.openclaw/tools/node/bin/node` directly.
- Added a 15-minute installer watchdog when GNU `timeout` is available.

## v1.10.3

- Fixed WSL resolving the native Windows npm OpenClaw launcher after the Windows installer completed.
- Toolkit WSL commands use a Linux-only PATH.
- WSL OpenClaw/Node verification rejects Windows-mounted launchers.

## v1.10.2

- Fixed Windows PowerShell 5.1 installer byte-array coercion (`35 32 79 112...`).
- Downloads the official Windows installer to a temporary `.ps1` and executes it via child PowerShell `-File`.
- Adds download sanity checks, curl fallback and PATH refresh.

## v1.10.1

- Fixed `C:\dev\null` failure caused by C-style quote escaping inside Windows PowerShell strings.
- Bash `/dev/null` redirection stays inside WSL.

## v1.10.0

- Replaced fragile Store/first-launch Ubuntu provisioning on empty new PCs with deterministic Ubuntu 24.04 WSL rootfs import.
- Verifies Canonical SHA-256 before import.
- Creates/configures an OpenClaw user and systemd non-interactively.

## v1.9.x

- Added self-bootstrapping new-PC restore, prerequisite fallback/resume, restore-launcher path fixes, full-backup restore scripts and reset/repair mode.
