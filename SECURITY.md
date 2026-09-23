# Security Policy

## Sensitive backups

This project creates backup and migration packages that may contain highly sensitive OpenClaw data, including credentials, tokens, configuration, session history and agent state.

Do not publish real backup archives, migration ZIPs, tokens, `openclaw.json`, private logs or recovered state in a public GitHub issue.

## Reporting a problem

1. Reproduce it with sanitized/test data when possible.
2. Remove access tokens, API keys, session identifiers, email addresses, usernames and private paths.
3. Do not upload a real `Payload/*.tar.gz` backup.
4. Do not upload `windows-openclaw-state.zip` from a real deployment.
5. Review logs manually before sharing.

## Repair mode

The reset/repair workflow can stop processes, remove stale duplicate node registrations, reinstall OpenClaw service definitions and rebuild a Windows CUA node. It deliberately does not auto-approve new device or command-surface security requests.
