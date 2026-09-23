# Changelog

v1.10.5
- Fix WSL OpenClaw detector syntax error.
- Prefer canonical Linux OpenClaw and private Node binaries.
- Retain post-install freeze fix and watchdog.

## v1.10.4

- Fixed apparent freeze immediately after a successful WSL OpenClaw installation.
- The affected run had already completed `install-cli.sh` successfully and then stopped during a non-essential `~/.local/bin` symlink / `~/.profile` mutation.
- Removed that post-install profile/symlink mutation entirely.
- After installer success the toolkit now verifies the canonical runtime files directly: `~/.openclaw/bin/openclaw` and `~/.openclaw/tools/node/bin/node`.
- Runs both canonical binaries with `--version` before proceeding.
- Added a 15-minute installer watchdog with GNU `timeout` when available.
- Retains all v1.10.3 PATH isolation, v1.10.2 Windows installer fixes, v1.10.1 `/dev/null` fix, deterministic WSL provisioning, backup/migration verification, fallback/resume and reset/repair behavior.

## v1.10.3

- Fixed WSL resolving the native Windows npm OpenClaw launcher after the Windows installer completed.
- Every toolkit WSL command now receives a Linux-only PATH.
- WSL OpenClaw/Node verification rejects `/mnt/*`, `.cmd` and `.exe` resolutions.
- The staged restore uses the same Linux-only runtime isolation.

## v1.10.2

- Fixed Windows PowerShell 5.1 installer byte-array coercion (`35 32 79 112...`).
- Downloads the official Windows installer to a temporary `.ps1` and executes it via child PowerShell `-File`.
- Adds download sanity checks, curl fallback and PATH refresh.

## v1.10.1

- Fixed `C:\dev\null` failure caused by C-style quote escaping inside Windows PowerShell strings.
- Bash `/dev/null` redirection now stays inside WSL.
- Added WSL shell-routing self-test.

## v1.10.0

- Replaced fragile Store/first-launch Ubuntu provisioning on empty new PCs with deterministic Ubuntu 24.04 WSL rootfs import.
- Verifies Canonical SHA-256 before import.
- Creates/configures an OpenClaw user and systemd non-interactively.

## v1.9.x

- Added self-bootstrapping new-PC restore, prerequisite fallback/resume, restore launcher path fixes, full-backup restore scripts and reset/repair mode.
