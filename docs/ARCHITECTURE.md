# Architecture

## Supported topology

```text
Windows 11
│
├── OpenClaw companion / Windows CUA node
├── Hatch IQ backup / restore toolkit
└── WSL2
    └── Linux distro
        └── systemd user service
            └── OpenClaw Gateway
                └── 127.0.0.1:18789
```

The repair path treats the WSL Gateway as authoritative. A separate native-Windows Gateway is considered a competing instance for this topology.

## Backup flow

```text
Stop WSL Gateway
      ↓
OpenClaw backup create
      ↓
OpenClaw backup verify
      ↓
WSL-native verified tar.gz
      ↓
raw binary transfer to Windows
      ↓
byte-count comparison
      ↓
SHA-256 comparison
      ↓
package manifest
      ↓
portable ZIP
      ↓
ZIP reopen / validation
```

The critical archive handoff intentionally avoids depending on `/mnt/c` visibility timing or `\\wsl.localhost`.

## Restore flow

The restore package is verified before live state is changed. OpenClaw restore is performed into staging, recorded assets are activated, and rollback locations are retained for recovery.
