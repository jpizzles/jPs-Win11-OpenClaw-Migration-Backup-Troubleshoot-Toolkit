# Hatch IQ OpenClaw Toolkit v1.12.2

## Automatic Windows Hub setup code

After a successful NEW-PC migration, the toolkit now automatically mints a short-lived
OpenClaw Windows Hub setup code from the restored WSL Gateway and prints it prominently
for copy/paste into:

`OpenClaw Companion -> Connection -> Setup code`

The setup payload is validated before display and is not written to `tool-run.log`: the
PowerShell transcript is stopped before the bootstrap credential is generated.

This release also includes all prior migration hardening through v1.12.1:
- verified OpenClaw backup + restore staging
- transactional state activation with rollback
- Windows PowerShell 5.1-safe WSL transport
- WSL distro launch normalization/probing
- Windows Hub installation and connection guidance
- durable Windows CUA paired-node state migration
- automatic short-lived node bootstrap fallback
- package/archive integrity verification

SHA-256:

`be8c1999a1cd1777eca55b8cdbc2f7362f6246851eabdc479fa66eca7cb3f955`
