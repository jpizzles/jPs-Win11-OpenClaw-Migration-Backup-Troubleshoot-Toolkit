# Contributing

Thanks for helping improve the Hatch IQ OpenClaw Toolkit.

Before opening a change:

- keep Windows PowerShell 5.1 compatibility unless a breaking change is explicitly justified;
- preserve the WSL-Gateway + Windows-CUA topology assumptions documented in `docs/ARCHITECTURE.md`;
- do not weaken backup verification or checksum checks;
- do not silently auto-approve OpenClaw security/device requests;
- never include real credentials, tokens, backup archives or private logs;
- prefer fail-closed behavior for backup and restore integrity.

Useful bug-report details include Windows version, PowerShell version, WSL distro, OpenClaw version, toolkit version, failing stage, and a sanitized excerpt from `tool-run.log`.
