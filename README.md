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
  <img alt="Release" src="https://img.shields.io/badge/release-v1.10.5-22C55E">
</p>

> Created by **Hatch IQ** as an independent community utility for OpenClaw backup, migration, restore, recovery, reset and debugging workflows.

## Current release — v1.10.5

Download the complete toolkit:

[`dist/OpenClaw_Backup_Migration_Toolkit_v1.10.5.zip`](dist/OpenClaw_Backup_Migration_Toolkit_v1.10.5.zip)

The ZIP contains the actual `OpenClaw-Backup-Migrate.ps1`, double-click launcher, restore helpers, changelog and README. Extract it before running.

## What it does

The toolkit is designed around a common OpenClaw topology:

- WSL2 hosts the real OpenClaw Gateway.
- Windows 11 hosts the companion/CUA node.
- Backups are independently verified before acceptance.
- Migration packages carry their own restore/bootstrap tooling.
- New-PC restore can provision prerequisites automatically.
- Repair mode cleans duplicate processes/nodes, rebuilds services and validates the stack.

The design is fail-closed: if archive creation, transfer, checksum verification, prerequisite installation or restore verification cannot be confirmed, the toolkit stops and reports the problem instead of pretending the operation succeeded.

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

On the source machine, choose option 2 and move the resulting ZIP to the destination Windows 11 machine.

After extraction, use:

```text
RESTORE-ON-NEW-PC.cmd
```

For an older already-verified backup package, the latest toolkit also contains:

```text
RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd
CHECK-EXISTING-PACKAGE-NEW-PC-PREREQUISITES.cmd
```

You do not need to rewrite or invalidate the old backup package just to use a newer restore engine.

## New-PC prerequisite bootstrap

Before restored state is activated, the toolkit checks and, where possible, installs:

- WSL / WSL2
- Ubuntu 24.04 when no usable distro exists
- systemd
- Linux restore utilities
- native Linux/WSL OpenClaw
- the private Linux Node runtime
- native Windows OpenClaw
- the Windows Node runtime required by the OpenClaw installer

If automated installation cannot safely complete, the toolkit stops before partial state activation and writes:

```text
Documents\OpenClaw-Restore-Logs\<run>\
    RESTORE-FALLBACK-INSTRUCTIONS.txt
    CONTINUE-RESTORE.cmd
```

Complete the listed prerequisite and run `CONTINUE-RESTORE.cmd`; the prerequisite checks are repeated before restore continues.

## v1.10.5 — WSL canonical runtime detection

v1.10.5 fixes the native WSL OpenClaw detector that could throw a Bash syntax error around `/mnt/*` before the installer ran. The toolkit now prefers the canonical Linux runtime files directly:

```text
~/.openclaw/bin/openclaw
~/.openclaw/tools/node/bin/node
```

It rejects Windows-mounted `.cmd`/`.exe` launchers with simple path checks rather than the previous fragile Bash `case` expression.

The v1.10.4 post-install reliability fix is retained: there is no non-essential `~/.profile` mutation or `~/.local/bin/openclaw` symlink step after installation. Both canonical binaries are verified directly, and the WSL OpenClaw installer has a 15-minute watchdog when Linux `timeout` is available.

## Recent reliability fixes

- v1.10.4 removes the post-install profile/symlink step that could appear to freeze after OpenClaw had already installed successfully.
- v1.10.3 isolates all toolkit WSL commands from inherited Windows PATH entries so `/mnt/c/.../npm/openclaw` cannot replace the native Linux CLI.
- v1.10.2 downloads the Windows OpenClaw installer to a real `.ps1` file and executes it with `powershell.exe -File`, avoiding PowerShell 5.1 byte-array coercion failures.
- v1.10.1 fixes PowerShell parsing of Linux `/dev/null` redirection.
- v1.10.0 replaces flaky Store/first-launch provisioning on empty new PCs with deterministic Ubuntu 24.04 `wsl --import` provisioning and Canonical SHA-256 verification.

## Backup integrity

The backup flow uses layered validation:

1. OpenClaw creates the archive.
2. OpenClaw reports `verified=true`.
3. `openclaw backup verify` runs independently.
4. Source byte count is checked in WSL.
5. The archive is moved to Windows through the toolkit's raw binary transfer path.
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

## Security

Generated backup/migration packages may contain credentials, tokens, session history, agent state and configuration. Treat them like a password vault.

Do not upload real personal backup packages or unsanitized logs to public GitHub issues.

See [`SECURITY.md`](SECURITY.md).

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md)
- [`RELEASE_NOTES_v1.10.5.md`](RELEASE_NOTES_v1.10.5.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/NEW-PC-MIGRATION.md`](docs/NEW-PC-MIGRATION.md)
- [`docs/RESET-REPAIR.md`](docs/RESET-REPAIR.md)

## Credits

**Hatch IQ** — design, workflow development, testing and packaging of the OpenClaw Backup, Migration & Recovery Toolkit.

OpenClaw is a separate project. This repository is an independent community utility and is not presented as an official OpenClaw product.

## License

No open-source license has been selected yet. Public availability does not by itself grant redistribution or modification rights.
