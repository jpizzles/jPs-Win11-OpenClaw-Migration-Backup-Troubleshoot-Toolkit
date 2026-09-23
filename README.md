# Hatch IQ OpenClaw Backup, Migration & Recovery Toolkit

<p align="center">
  <b>Back it up. Move it. Restore it. Repair it.</b><br>
  Windows 11 + WSL2 backup, migration, restore, reset and troubleshooting for OpenClaw.
</p>

<p align="center">
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white">
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white">
  <img alt="WSL2" src="https://img.shields.io/badge/WSL-2-FCC624?logo=linux&logoColor=black">
  <img alt="OpenClaw" src="https://img.shields.io/badge/OpenClaw-Backup%20%7C%20Migration%20%7C%20Repair-111827">
  <img alt="Hatch IQ" src="https://img.shields.io/badge/Created%20by-Hatch%20IQ-7C3AED">
  <img alt="Release" src="https://img.shields.io/badge/release-v1.10.6-22C55E">
</p>

> Created by **Hatch IQ** as an independent community utility for OpenClaw backup, migration, restore, recovery, reset and debugging workflows.

## Current release — v1.10.6

Download the complete toolkit:

[`dist/OpenClaw_Backup_Migration_Toolkit_v1.10.6.zip`](dist/OpenClaw_Backup_Migration_Toolkit_v1.10.6.zip)

SHA-256: `55474b2f1f63573dfd19aff156ab4c80ba061c43a8413aa747311484a969af43`

Extract the ZIP before running. The distribution contains the actual PowerShell engine, double-click launcher, restore/new-PC helpers, changelog and toolkit README.

## What it does

The toolkit is designed around a Windows 11 + WSL2 OpenClaw topology:

- WSL2 hosts the OpenClaw Gateway.
- Windows hosts the companion/CUA node.
- Backups are independently verified before acceptance.
- Migration packages carry their own restore/bootstrap tooling.
- New-PC restore can provision prerequisites automatically.
- Repair mode cleans duplicate processes/nodes, rebuilds services and validates the stack.

The design is fail-closed: if archive creation, transfer, checksum verification, prerequisite installation or restore verification cannot be confirmed, the toolkit stops and reports the problem rather than pretending the operation succeeded.

## Main menu

```text
[1] Full verified backup
[2] Create portable migration kit
[3] Restore / migrate onto THIS computer
[4] Verify an existing backup / migration package
[5] Diagnostics only
[6] Full reset / repair / clean restart
[7] Finalize an existing package into a Desktop ZIP
```

## New-PC migration

On the source machine, choose option 2 and move the resulting ZIP to the destination Windows 11 machine. After extraction, run:

```text
RESTORE-ON-NEW-PC.cmd
```

For an older already-verified backup package, use the current restore engine without modifying the old package:

```text
RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd
CHECK-EXISTING-PACKAGE-NEW-PC-PREREQUISITES.cmd
```

The original package manifest/checksums are revalidated before state activation.

## v1.10.6 — robust Windows-to-WSL script transport

The largest change in v1.10.6 is architectural: multiline Bash programs are no longer embedded inside a Windows native command argument such as `bash -lc <script>`.

Windows PowerShell 5.1 and `wsl.exe` can reinterpret quoting, variables and command substitution at that boundary. Previous releases could therefore install OpenClaw successfully and then lose Bash variables in a later verification command.

v1.10.6 now:

1. writes each toolkit Bash program to a temporary UTF-8/no-BOM, LF-only `.sh` file;
2. invokes it with `bash --noprofile --norc <script-file>`;
3. uses the same mechanism for root-level WSL setup;
4. runs a variable/quoting/command-substitution transport self-test before OpenClaw setup;
5. verifies the canonical WSL binaries directly:

```text
~/.openclaw/bin/openclaw
~/.openclaw/tools/node/bin/node
```

6. uses the same canonical runtime during staged restore and post-restore runtime repair;
7. preserves literal Linux `$HOME` in generated fallback instructions instead of expanding it to the Windows home directory.

## New-PC prerequisite bootstrap

Before restored state is activated, the toolkit checks and, where possible, installs:

- WSL / WSL2
- a usable Ubuntu environment
- systemd
- Linux restore utilities
- native Linux/WSL OpenClaw
- the private Linux Node runtime
- native Windows OpenClaw
- the Windows runtime required by the OpenClaw installer

If WSL is installed but no usable Linux distro exists, the toolkit can deterministically provision Ubuntu 24.04 using a Canonical WSL rootfs and SHA-256 verification.

If automatic installation cannot safely complete, the toolkit stops before partial state activation and writes:

```text
Documents\OpenClaw-Restore-Logs\<run>\
    RESTORE-FALLBACK-INSTRUCTIONS.txt
    CONTINUE-RESTORE.cmd
```

Complete the listed prerequisite and run `CONTINUE-RESTORE.cmd`; prerequisite checks are repeated before restore continues.

## Recent reliability fixes

- **v1.10.6** replaces fragile inline `bash -lc` transport with script-file transport and fixes Linux `$HOME` fallback instructions.
- **v1.10.5** prefers canonical Linux OpenClaw/Node binaries and removes a fragile Bash detector.
- **v1.10.4** removes a post-install profile/symlink step that could appear to freeze after OpenClaw was already installed and adds an installer watchdog.
- **v1.10.3** isolates WSL commands from inherited Windows npm/OpenClaw PATH entries.
- **v1.10.2** downloads the Windows OpenClaw installer to a real `.ps1` file and runs it with child PowerShell `-File`, avoiding byte-array coercion failures.
- **v1.10.1** fixes Windows PowerShell parsing of Linux `/dev/null` redirection.
- **v1.10.0** adds deterministic Ubuntu 24.04 provisioning for empty new PCs.

## Backup integrity

The backup path uses layered validation:

1. OpenClaw creates the archive.
2. OpenClaw reports `verified=true`.
3. `openclaw backup verify` runs independently.
4. Source byte count is checked in WSL.
5. The archive is streamed from `wsl.exe` as raw bytes into a Windows `FileStream`.
6. Windows and WSL byte counts must match.
7. WSL SHA-256 must match Windows `Get-FileHash`.
8. Package manifest hashes are validated.
9. The portable ZIP is reopened and inspected.
10. The expected OpenClaw archive and manifest must exist inside the ZIP.

## Reset / repair / debug

Option 6 can:

- stop the Windows companion
- stop the Windows CUA scheduled node
- terminate duplicate/orphan `node run` process trees
- remove an accidental competing native-Windows Gateway
- stop and rebuild the WSL Gateway service
- attempt a pre-repair safety backup
- run Doctor/update repair
- rebuild Windows CUA
- repair exec-node binding
- verify CUA capabilities
- check pending approvals
- require a healthy final Gateway deep probe
- require exactly one Windows node-host root process tree

It intentionally does not silently approve new OpenClaw security/device requests.

## Full-backup restore

A normal option-1 Full Backup is independently restorable. After extracting it, run:

```text
RESTORE-THIS-BACKUP.cmd
```

Restore is staged and verified before live state is activated.

## Security

Generated backup/migration packages may contain credentials, tokens, session history, agent state and configuration. Treat them like a password vault.

Do not upload real personal backup packages or unsanitized logs to public GitHub issues. See [`SECURITY.md`](SECURITY.md).

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md)
- [`RELEASE_NOTES_v1.10.6.md`](RELEASE_NOTES_v1.10.6.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/NEW-PC-MIGRATION.md`](docs/NEW-PC-MIGRATION.md)
- [`docs/RESET-REPAIR.md`](docs/RESET-REPAIR.md)

## Requirements

Primary target:

- Windows 11
- Windows PowerShell 5.1+
- WSL2
- OpenClaw
- systemd-enabled Linux environment for the Gateway

## Credits

**Hatch IQ** — design, workflow development, testing and packaging of the OpenClaw Backup, Migration & Recovery Toolkit.

OpenClaw is a separate project. This repository is an independent community utility and is not presented as an official OpenClaw product.

## License

No open-source license has been selected yet. Public availability does not by itself grant redistribution or modification rights.
