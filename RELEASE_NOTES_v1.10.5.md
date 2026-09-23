# Hatch IQ OpenClaw Toolkit v1.10.5

## WSL OpenClaw detector + post-install reliability fix

This release fixes both problems observed in the latest new-PC restore log:

1. The native WSL OpenClaw detector could fail with `bash: -c: syntax error near unexpected token '/mnt/*'`.
2. After OpenClaw installed successfully, a non-essential profile/symlink step could appear to freeze.

Changes:
- prefer `~/.openclaw/bin/openclaw` directly;
- prefer `~/.openclaw/tools/node/bin/node` directly;
- remove fragile Bash `case` glob alternation;
- reject `/mnt/*`, `.cmd`, and `.exe` launchers using simple path checks;
- remove post-install `~/.profile` mutation and symlink creation;
- verify the canonical OpenClaw and private Node binaries directly;
- retain a 15-minute installer watchdog.

All earlier Windows installer, WSL path-isolation, deterministic WSL provisioning, backup/migration verification, fallback/resume, and reset/repair fixes remain intact.

GitHub release ZIP SHA-256: `cd23ebc47b42d5c0fc48e5d5b18ec98c2e4914d26ee4909dd6f36ea1ad81afcc`
