# v1.10.4 — WSL OpenClaw post-install freeze fix

The affected new-PC restore had already installed OpenClaw successfully, then appeared to hang while the toolkit edited `~/.profile` and created a `~/.local/bin/openclaw` symlink.

v1.10.4:

- removes that unnecessary shell-profile/symlink mutation;
- verifies `~/.openclaw/bin/openclaw` directly;
- verifies `~/.openclaw/tools/node/bin/node` directly;
- runs both canonical binaries with `--version`;
- adds a 15-minute installer watchdog using Linux `timeout` when available;
- preserves the Linux-only PATH isolation throughout restore.

All previous backup, migration, restore, verification, WSL provisioning, Windows installer, PATH isolation and reset/repair fixes remain.

Download: [`dist/OpenClaw_Backup_Migration_Toolkit_v1.10.4.zip`](dist/OpenClaw_Backup_Migration_Toolkit_v1.10.4.zip)
