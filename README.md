# Hatch IQ OpenClaw Backup, Migration & Recovery Toolkit

<p align="center">
  <b>Back it up. Move it. Restore it. Repair it.</b><br>
  Windows 11 + WSL2 backup, migration, restore, recovery and troubleshooting for OpenClaw.
</p>

<p align="center">
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D4?logo=windows11&logoColor=white">
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white">
  <img alt="WSL2" src="https://img.shields.io/badge/WSL-2-FCC624?logo=linux&logoColor=black">
  <img alt="Hatch IQ" src="https://img.shields.io/badge/Created%20by-Hatch%20IQ-7C3AED">
  <img alt="Release" src="https://img.shields.io/badge/release-v1.12.3-22C55E">
</p>

> Created by **Hatch IQ** as an independent community utility for OpenClaw backup, migration, restore, recovery, reset and debugging workflows.

## Current release — v1.12.3

Download the complete toolkit:

[`dist/OpenClaw_Backup_Migration_Toolkit_v1.12.3.zip`](dist/OpenClaw_Backup_Migration_Toolkit_v1.12.3.zip)

SHA-256: `b970170eab9724c2ead58c3dc33456003db7cda1d980c5832c59780a5a893a8c`

Extract the ZIP before running.

## What it does

The toolkit is designed around a Windows 11 + WSL2 OpenClaw topology:

- WSL2 hosts the OpenClaw Gateway.
- Windows hosts OpenClaw Windows Hub / Companion and the Windows CUA node.
- Backups are verified before acceptance.
- Migration packages carry their own restore/bootstrap tooling.
- New-PC restore can provision prerequisites automatically.
- Restore activation is staged and transactional with rollback protection.
- Windows CUA pairing state is migrated without requiring users to paste the shared Gateway token.
- Repair mode cleans duplicate processes/nodes, rebuilds services and validates the stack.

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

On the source machine, create a migration kit and move the resulting ZIP to the destination Windows 11 PC. After extraction, run:

```text
RESTORE-ON-NEW-PC.cmd
```

For an older already-verified package, use the current engine:

```text
RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd
CHECK-EXISTING-PACKAGE-NEW-PC-PREREQUISITES.cmd
```

## v1.12.3 — local or existing-remote Gateway connection

After a successful NEW-PC migration, the toolkit now explains both Windows Hub connection topologies.

### A. Restored local WSL Gateway

The migration automatically mints a fresh short-lived Windows Hub setup code for the restored local Gateway and prints it for:

```text
OpenClaw Companion -> Connection -> Setup code
```

Local Gateway URL:

```text
ws://127.0.0.1:18789
```

### B. Existing remote Gateway over Tailscale Serve

If the new PC should attach to an already-running Gateway on another machine, the toolkit now includes the Direct connection flow:

```text
OpenClaw Companion -> Connection -> Direct
wss://<gateway-host>.<tailnet>.ts.net
```

On the existing Gateway host, first verify:

```text
tailscale serve status
```

If Serve is already proxying the tailnet HTTPS endpoint to `http://127.0.0.1:18789`, do not reconfigure Serve.

Retrieve the shared token only in an interactive terminal on the existing Gateway host:

```bash
~/.openclaw/bin/openclaw gateway auth-token --show
```

If a shared token was exposed, rotate it on that Gateway host:

```bash
~/.openclaw/bin/openclaw doctor --generate-gateway-token
~/.openclaw/bin/openclaw gateway restart
~/.openclaw/bin/openclaw gateway auth-token --show
```

Device approval and the separate Windows CUA/node approval must be completed on the Gateway the new PC is actually connecting to.

## Reliability hardening through v1.12.x

Recent releases include:

- Windows PowerShell 5.1-safe WSL script transport over STDIN.
- WSL distro-name normalization and real launch probing.
- deterministic Ubuntu 24.04 provisioning for empty new PCs.
- canonical native-Linux OpenClaw and Node runtime checks.
- Windows OpenClaw installer byte-array and PATH fixes.
- transactional restore activation with pre-copy validation and automatic rollback.
- UTF-8/no-BOM generated Linux restore scripts.
- Windows Hub installation using official GitHub release metadata, asset digest verification and Authenticode validation.
- complete Windows `.openclaw` snapshot using .NET ZIP APIs rather than wildcard `Compress-Archive`.
- Windows paired-node SQLite identity recovery.
- short-lived node bootstrap enrollment fallback.
- explicit Windows Hub connection guide and automatic final Setup code.
- existing-remote Gateway/Tailscale Direct connection guidance.

## Backup integrity

The toolkit uses layered validation:

1. OpenClaw creates the archive.
2. OpenClaw reports verification.
3. `openclaw backup verify` runs independently.
4. Source size is checked in WSL.
5. The archive is streamed from WSL as raw bytes into a Windows FileStream.
6. WSL/Windows byte counts must match.
7. WSL SHA-256 must match Windows `Get-FileHash`.
8. Package manifest hashes are validated.
9. The portable ZIP is reopened and inspected.
10. Restore revalidates the package before state activation.

## Restore safety

Restore is staged before activation. All staged source assets are resolved and validated before live state changes. Replacement assets are prepared first, existing destinations are moved into rollback storage, and already-swapped destinations are automatically restored if a later activation step fails.

## Windows Hub / Companion

After migration, use the restored local Gateway or deliberately select an existing remote Gateway. Do not accidentally install a second Gateway from Windows Hub.

The restore log writes `CONNECT-WINDOWS-HUB.txt` with both connection flows.

## Security

Backup/migration packages may contain credentials, durable pairing state, session history, agent state and configuration. Treat them like a password vault.

Do not upload real personal backup packages or unsanitized logs to public GitHub issues.

## Documentation

- [`CHANGELOG.md`](CHANGELOG.md)
- [`RELEASE_NOTES_v1.12.3.md`](RELEASE_NOTES_v1.12.3.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/NEW-PC-MIGRATION.md`](docs/NEW-PC-MIGRATION.md)
- [`docs/RESET-REPAIR.md`](docs/RESET-REPAIR.md)

## Requirements

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
