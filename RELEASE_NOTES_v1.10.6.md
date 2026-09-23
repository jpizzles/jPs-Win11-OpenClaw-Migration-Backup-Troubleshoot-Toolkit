# Hatch IQ OpenClaw Toolkit v1.10.6

## Fundamental WSL script-transport fix

The latest new-PC restore log showed that the canonical WSL OpenClaw and private Node binaries worked immediately after installation, but a later prerequisite script lost its own Bash variables. The failure was in the Windows PowerShell 5.1 -> `wsl.exe` -> inline `bash -lc` argument transport, not the OpenClaw installation.

### Changes

- Bash programs are written to temporary UTF-8/no-BOM, LF-only `.sh` files.
- WSL executes them with `bash --noprofile --norc` instead of receiving multiline shell source inside a Windows native command-line argument.
- Root-level WSL initialization/systemd/package-install commands use the same robust transport.
- A variable/quoting/command-substitution transport self-test runs before OpenClaw setup.
- Prerequisite validation directly executes `~/.openclaw/bin/openclaw` and `~/.openclaw/tools/node/bin/node`.
- Staged restore and post-restore runtime refresh use the same canonical local-prefix runtime.
- Generated fallback guides now preserve literal Linux `$HOME` rather than expanding it to a Windows user path.
- Misleading Windows PATH-probe `Test-Path: Access is denied` transcript noise is avoided.
- All prior backup, migration, deterministic WSL provisioning, installer, checksum, fallback/resume and reset/repair fixes are retained.

SHA-256: `55474b2f1f63573dfd19aff156ab4c80ba061c43a8413aa747311484a969af43`

Size: `50460 bytes`
