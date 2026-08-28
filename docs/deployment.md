# Web control-plane deployment

## Sources of truth

Treat the Release workflow and signed manifest as the build contract, the selected GitHub Release as the artifact source, and live service/deployment state as runtime truth. Repository examples and prior logs are guidance only. Resolve `<tag>`, commit, architecture, manifest identity, and current service state before installation, update, rollback, or diagnosis.

Signed Releases contain Linux amd64/arm64 control, server, and deploy-host artifacts plus macOS amd64/arm64 Runtime artifacts. Installation and updates verify the GitHub OIDC/Sigstore identity and every SHA-256; unsigned artifacts are rejected.

Linux supports two independent lanes. Native installation runs control under systemd. Container installation runs only deploy-host under systemd; deploy-host owns the control container while control remains the sole owner of server. The lanes must not share a state directory. The macOS Runtime is not containerized and does not use launchd to connect to the App's private Socket.

## Container lane

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap-container.sh --release-dir ./release
```

The bootstrap installs only `cc-connect-deploy-host.service`. The host executor is restricted to repository `shusfun/cc-connect`, image `ghcr.io/shusfun/cc-connect`, Compose project `cc-connect`, and service `cc-connect`. Its bundled `compose.yaml` is an executor input, not a standalone production entry point.

The container binds Web to `127.0.0.1:9820`, runs as UID/GID 10001 with a read-only root filesystem, and persists state under `/var/lib/cc-connect-docker/control` and `/var/lib/cc-connect-docker/app`. control never mounts the Docker Socket; it reaches deploy-host through the restricted Unix Socket. Web update and rollback remain control-owned business transactions, while deploy-host owns container replacement and watchdog rollback to the previous signed digest.

## Native systemd lane

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap.sh --release-dir ./release
```

The bootstrap creates release slots under `/opt/cc-connect/releases`, control state under `/var/lib/cc-connect/control`, app state under `/var/lib/cc-connect/app`, and private sockets under `/run/cc-connect`. systemd manages only control; control exclusively supervises server.

## Initial setup and Runtime pairing

The first start listens only on `127.0.0.1:9820` and exposes a one-time setup token through the applicable service log. Use SSH forwarding to complete Web setup: create the administrator, save the public HTTPS origin, pair Runtime, validate Codex and at least one project, optionally configure WeCom, then atomically generate configuration and start server. Apply the Release's `openresty-1panel.conf` to the existing HTTPS site.

Run the setup page's Runtime command in the current Codex Desktop App interactive terminal, equivalent to:

```bash
curl -fsSL https://cc.example.com/runtime/v1/install.sh -o cc-connect-runtime-install.sh
sh cc-connect-runtime-install.sh --server https://cc.example.com --code <code> --tag <tag>
```

After verification, installation, and pairing, the installer starts the Node supervisor from that App terminal. The terminal may be closed after startup; supervisor and worker output is persisted in `~/Library/Application Support/cc-connect-runtime/logs/runtime.log`, and the supervisor keeps Runtime online while Codex App is running. The installer stops and precisely removes the obsolete `dev.cc-connect.runtime` LaunchAgent. Restart an installed Runtime from an App terminal with:

```bash
"$HOME/Library/Application Support/cc-connect-runtime/current/cc-connect-runtime" --cosign "$(command -v cosign)"
```

The Ed25519 private key stays in macOS Keychain. The launcher re-execs into the App-bundled Node supervisor and passes the verified App Socket to the Go worker through an inherited fd. The supervisor survives launch-terminal detachment and individual worker exits; after an update, worker failure, or App Socket disconnect, it cleans up the old generation, starts the worker from the `current` Release, and scans for the new Socket. Runtime connects outbound over TLS/WebSocket; catalog sync sends opaque project metadata and never conversation bodies. Runtime never starts a second Codex App Server.

## Updates, rollback, and diagnosis

Updates and rollback are initiated from Web. control checks active operations, backs up `control.db`, coordinates Runtime activation, and shares one execution slot with restart. The native lane switches signed release slots and uses systemd recovery. The container lane asks deploy-host to switch a verified digest and uses its persisted activation state. Do not manually edit release links, activation records, deployer state, or database backups.

Start diagnosis from the reported symptom, UTC window, target tag/commit, and live operations state. Select only signals that can distinguish the current hypotheses; logs and commands below are candidates, not a checklist.

- Native lane: Web operations state, `systemctl status cc-connect-control.service`, and `journalctl -u cc-connect-control.service`.
- Container lane: Web operations state, `systemctl status cc-connect-deploy-host.service`, deploy-host journal, and read-only container status/logs for the expected image digest.
- Runtime: the paired device's connection history, `~/Library/Application Support/cc-connect-runtime/logs/runtime.log`, and the control-side run or request correlation ID.

Before retrying or cancelling, reread the current run state and one independent signal such as log freshness, health, execution-slot state, or candidate revision. Preserve activation and backup evidence when automatic recovery fails.
