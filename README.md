# Hatch IQ OpenClaw Backup, Migration & Recovery Toolkit

<p align="center">
  <b>Back up it. Move it. Restore it. Repair it.</b><br>
  A Windows 11 + WSL2 recovery toolkit for OpenClaw.
</p>

<p align="center">
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white">
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white">
  <img alt="WSL2" src="https://img.shields.io/badge/WSL-2-FCC624?logo=linux&logoColor=black">
  <img alt="OpenClaw" src="https://img.shields.io/badge/OpenClaw-Backup%20%7C%20Migration%20%7C%20Repair-111827">
  <img alt="Hatch IQ" src="https://img.shields.io/badge/Created%20by-Hatch%20IQ-7C3AED">
</p>

> **Created by Hatch IQ** as an independent community utility for OpenClaw backup, migration, restore, recovery, reset and debugging workflows.

## What it does

The Hatch IQ OpenClaw Toolkit is a double-clickable Windows PowerShell utility designed around a common OpenClaw topology:

- **WSL2** hosts the real OpenClaw Gateway.
- **Windows 11** hosts the companion/CUA node.
- Backups are verified before they are accepted.
- Migration packages include their own restore/bootstrap scripts.
- Repair mode can stop duplicate processes, rebuild services/nodes and validate a clean restart.

The toolkit was built to fail closed: when a backup, transfer, checksum, restore prerequisite or recovery check cannot be verified, it reports the problem instead of pretending the operation succeeded.

## Highlights

| Capability | What it does |
|---|---|
| Full verified backup | Stops the Gateway safely, creates an OpenClaw archive, verifies it, exports it to Windows and builds a portable ZIP |
| New-PC migration kit | Creates a portable package with restore scripts and prerequisite bootstrap |
| Full restore | Verifies package checksums, stages the restore, activates recovered state, rebuilds services and validates health |
| New-PC bootstrap | Checks WSL, Linux distro, systemd, Linux utilities, Windows OpenClaw and WSL OpenClaw before restoring |
| Fail-safe installer fallback | Generates manual instructions + `CONTINUE-RESTORE.cmd` if an automatic prerequisite install cannot finish |
| Reset / repair / debug | Stops all known OpenClaw instances, removes duplicate runtime nodes, repairs Gateway/CUA services and reruns health checks |
| Package verification | SHA-256 validation plus OpenClaw's own backup verification |
| Portable Windows ZIP | Produces a single validated backup/migration ZIP for storage or transfer |

## Quick start

Download the latest packaged toolkit from `dist/`, extract it, and double-click:

```text
OpenClaw-Backup-Migrate.cmd
```

The menu provides:

```text
[1] Full verified backup
[2] Create portable migration kit
[3] Restore / migrate onto THIS computer
[4] Verify an existing backup / migration package
[5] Diagnostics only
[6] Full reset / repair / clean restart
[7] Finalize an existing package into a Desktop ZIP
```

## New PC migration

### Restoring older verified backup packages

You do not need to alter or regenerate an older verified package just to use a newer restore engine. Run `RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd` from the latest toolkit, select the existing package, and the toolkit verifies the package's original manifest before restore.

On the source PC, choose:

```text
2 - Create portable migration kit
```

Move the resulting ZIP to the destination Windows 11 PC, extract it, then use:

```text
RESTORE-ON-NEW-PC.cmd
```

The package also includes:

```text
CHECK-NEW-PC-PREREQUISITES.cmd
TEST-RESTORE-LAUNCHER.cmd
RESTORE-THIS-BACKUP.cmd
RESTORE-THIS-BACKUP.ps1
RESTORE-ON-NEW-PC.ps1
README-RESTORE.txt
```

### Deterministic WSL provisioning

If WSL is present but no Linux distro exists, v1.10.0 downloads Canonical's official Ubuntu 24.04 WSL rootfs, verifies Canonical's published SHA-256, and imports it directly as `OpenClawGateway` with `wsl --import`. This avoids Microsoft Store/first-launch registration timing problems on new PCs.

### Windows installer reliability

v1.10.2 downloads the official Windows OpenClaw installer to a temporary `.ps1` file and runs it with `powershell.exe -File -NoOnboard`, instead of constructing an in-memory scriptblock from `Invoke-WebRequest.Content`. This avoids byte-array coercion failures seen on some Windows PowerShell 5.1 builds.

### WSL / Windows runtime isolation

v1.10.3 isolates toolkit WSL commands from the inherited Windows PATH. This prevents native Windows npm/OpenClaw shims under `/mnt/c/...` from being selected instead of the WSL Gateway's rootless OpenClaw and Node runtimes.

### New-PC prerequisite bootstrap

Before touching restored OpenClaw state, the toolkit checks for:

- WSL / WSL2
- a usable Linux distribution
- systemd
- `curl`
- Python 3
- `tar`, `gzip`, `sha256sum` and related restore utilities
- OpenClaw inside WSL
- native Windows OpenClaw
- required Node runtime paths installed by the OpenClaw installers

Where possible, missing prerequisites are installed automatically.

If automated installation cannot safely complete — for example because Windows requires a reboot or a distro requires first-run setup — the toolkit stops before a partial restore and creates:

```text
Documents\OpenClaw-Restore-Logs\<run>\
    RESTORE-FALLBACK-INSTRUCTIONS.txt
    CONTINUE-RESTORE.cmd
```

Complete the listed prerequisite and run `CONTINUE-RESTORE.cmd`. The prerequisites are checked again before restore continues.

## Backup integrity

The backup path intentionally uses multiple independent checks:

1. OpenClaw creates the archive.
2. OpenClaw reports `verified=true`.
3. `openclaw backup verify` is run independently.
4. WSL reports the source byte count.
5. The archive is streamed as raw binary output through `wsl.exe` into a Windows `FileStream`.
6. WSL and Windows byte counts must match.
7. WSL SHA-256 must match Windows `Get-FileHash`.
8. Package manifest hashes are validated.
9. The final portable ZIP is reopened and inspected.
10. The expected OpenClaw archive and manifest must exist inside the ZIP.

## Reset / repair / debug mode

Option 6 is designed for a WSL-Gateway + Windows-CUA installation.

It can:

- stop the OpenClaw Windows companion
- stop the Windows CUA scheduled node
- terminate duplicate/orphaned `node run` process trees
- remove an accidental competing native-Windows Gateway
- stop and rebuild the WSL Gateway service
- create a best-effort pre-repair safety backup
- run OpenClaw Doctor repair
- run update/plugin repair
- rebuild the Windows CUA node
- verify the exec-node binding
- check CUA capabilities such as `computer.act`, `screen.snapshot`, and `system.run`
- check pending device/node approvals
- require a healthy final Gateway deep probe
- require a single Windows node-host root process tree at the end

The repair tool intentionally does **not** silently approve new OpenClaw security/device requests.

## Full-backup restore

A normal option-1 Full Backup is also independently restorable.

After extracting the backup ZIP:

```text
RESTORE-THIS-BACKUP.cmd
```

The restore is staged and verified before live state is activated.

## Security

OpenClaw backup packages may contain credentials, tokens, session history, agent state, configuration, and other sensitive material.

Treat generated backup and migration ZIPs like a password vault:

- keep them encrypted at rest
- do not upload personal backup ZIPs to a public repository
- do not attach real backup packages to public GitHub issues
- scrub tokens and personal paths from logs before posting them

See [`SECURITY.md`](SECURITY.md).

## Project layout

```text
.
├── OpenClaw-Backup-Migrate.ps1
├── OpenClaw-Backup-Migrate.cmd
├── README.md
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── NEW-PC-MIGRATION.md
│   └── RESET-REPAIR.md
└── dist/
    └── OpenClaw_Backup_Migration_Toolkit_v1.10.3.zip
```

## Requirements

Primary target:

- Windows 11
- Windows PowerShell 5.1+
- WSL2
- OpenClaw
- systemd-enabled Linux environment for the Gateway

The new-PC migration flow attempts to provision the missing prerequisites it can safely install.

## Status

Current packaged release: **v1.10.3**

This utility has been developed against a real Windows 11 + WSL OpenClaw deployment. OpenClaw CLI behavior can change between releases, so users should preserve a known-good backup and review repair output after OpenClaw upgrades.

## Credits

**Hatch IQ** — design, workflow development, testing and packaging of the OpenClaw Backup, Migration & Recovery Toolkit.

OpenClaw is a separate project. This repository is an independent community utility and is not presented as an official OpenClaw product.

## License

No open-source license has been selected yet. Public availability does not by itself grant redistribution or modification rights. Add a license before accepting third-party redistribution or contributions.
