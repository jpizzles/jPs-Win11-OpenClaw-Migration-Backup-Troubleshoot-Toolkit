# Reset / Repair / Clean Restart

Option 6 is the aggressive recovery path for deployments with stale services, duplicate Windows CUA nodes, orphaned `node run` processes or damaged service definitions.

It can stop the companion, Windows node task/processes and WSL Gateway; create a best-effort safety backup; run OpenClaw repair/update maintenance; reinstall the Gateway service definition; rebuild Windows CUA; repair exec-node binding; remove stale duplicate Windows CUA records when a connected keeper is unambiguous; and run final health checks.

The routine does not silently approve security/device requests.
