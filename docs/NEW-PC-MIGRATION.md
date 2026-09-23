# New-PC Migration

## Source PC

Run the toolkit and choose option 2. The generated migration ZIP contains the verified OpenClaw archive plus restore/bootstrap scripts.

## Destination PC

Extract the ZIP to a local Windows folder.

Recommended first step:

```text
TEST-RESTORE-LAUNCHER.cmd
```

Prepare prerequisites without activating a restore:

```text
CHECK-NEW-PC-PREREQUISITES.cmd
```

Perform the migration:

```text
RESTORE-ON-NEW-PC.cmd
```

## Existing older backup

Use the latest toolkit's `RESTORE-EXISTING-PACKAGE-ON-NEW-PC.cmd` and select the already-extracted package. The newer engine verifies the old package's original manifest before restore.

## Automatic prerequisite handling

The new-PC path checks WSL, distro availability, systemd, Linux utilities, WSL OpenClaw, native Linux Node, Windows OpenClaw and the Windows runtime. If an install cannot finish automatically, restore stops before state activation and creates a fallback guide plus `CONTINUE-RESTORE.cmd`.
