# Hatch IQ OpenClaw Toolkit v1.12.3

## Local or existing-remote Gateway connection guidance

After NEW-PC migration, the toolkit now explains both ways to bring OpenClaw Windows Hub online:

1. Connect to the restored local WSL Gateway using the automatically generated short-lived Setup code.
2. Connect this new PC to an existing Gateway on another machine over Tailscale Serve using a Direct `wss://` connection.

The generated `CONNECT-WINDOWS-HUB.txt`, `README-RESTORE.txt`, migration README, and final console now include:
- Tailscale Serve verification without reconfiguring a working Serve endpoint;
- `wss://<gateway-host>.<tailnet>.ts.net` Direct connection format;
- interactive remote token retrieval;
- remote device approval and separate node/CUA approval;
- token-rotation guidance if the shared token was exposed.

All v1.12.2 local Setup-code automation and earlier restore/rollback/pairing hardening remain.

SHA-256:

`c8701bfbfa683b0beb13d1f72592d774b3a35ae6efbb886bd518f6dc378dfa9d`
