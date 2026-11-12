# Installation and deployment

[Project home](../README.en.md) · [简体中文](deployment.md) · [Documentation](README.md) · [User guide (中文)](usage.md)

The desktop App works independently. Deploy a server only when you want NAS synchronization or a service that receives AI requests while the App is closed. The Docker instructions below create a **new deployment**. For an existing installation, use the [operations guide (中文)](../apps/server/OPERATIONS.md) before upgrading or moving data.

## Install the desktop App

Choose an attachment actually available for your platform on [Releases](https://github.com/ShiJiJS/chiyo/releases) and verify its SHA-256. Packages may lag behind the source: Windows adaptation and the latest features are in `main`, while the release page currently offers an earlier Mac development package. To use the latest source, follow the [development guide (中文)](development/README.md).

| Platform | Installation |
| --- | --- |
| macOS 14+, Apple Silicon | Open the DMG, drag `chiyo.app` into Applications, and launch Chiyo |
| Windows x64 | Extract the entire matching ZIP and run `app/info_desktop.exe`; retain adjacent DLLs, `data`, `cli`, and `tools`. Microsoft Visual C++ v14 x64 Runtime is required |

Mac development packages are locally signed and not notarized. An update may require you to allow Keychain access again; enter the system password yourself. Windows protects keys and private connection configuration with the current user's DPAPI and file permissions. Do not copy another computer's encrypted connection configuration.

On first launch, local mode lets you save information and handle local AI requests without Docker. Use the matching bundled CLI and instructions for [AI integration (中文)](../integrations/codex/README.md).

## Deploy the optional Docker server

Run the server on your own NAS or Linux host over trusted LAN HTTPS. Docker and Docker Compose are required; OpenSSL is included in the image. These instructions create a **new deployment**. Existing installations must retain their original configuration and mounts when updating the image.

### 1. Prepare private storage

Replace the bind address with the server's LAN address. Use the UID/GID that owns the data directory.

```sh
export CHIYO_STORAGE_DIRECTORY="$HOME/chiyo-data"
export CHIYO_BIND_ADDRESS="192.168.1.20"
export CHIYO_UID="$(id -u)"
export CHIYO_GID="$(id -g)"
export CHIYO_SOURCE_COMMIT="$(git rev-parse HEAD)"

umask 077
mkdir -p "$CHIYO_STORAGE_DIRECTORY/data" "$CHIYO_STORAGE_DIRECTORY/config"
cp deploy/server.example.json "$CHIYO_STORAGE_DIRECTORY/config/server.json"
```

### 2. Build and start

```sh
docker compose -f deploy/compose.yaml build
docker compose -f deploy/compose.yaml up -d
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail 50 chiyo
```

On an empty installation, `autoInitialize: true` creates persistent database keys, server identity, and TLS certificates under `data/server-identity/`. Restarts reuse these files. Missing keys or certificates for an existing database cause startup to fail instead of generating replacements. No manual certificate generation, copying, or `init-secrets` command is required.

The container listens on `47126`; set `CHIYO_PORT` to change the host port. The default bind address is loopback, so set `CHIYO_BIND_ADDRESS` for LAN access. Reuse the same environment values and private directory for maintenance. Never commit private deployment files.

`readCacheMiB` in `server.json` is a database read-cache budget: default 128 MiB, range 32–512, applied on restart. It is not a whole-process memory limit and does not preload attachments.

## Connect the App

1. Choose **Server sync** on first launch, or under **Settings → Storage & sync** later.
2. Enter the server IP/domain and port, without `https://`.
3. The App obtains and remembers the server certificate automatically. Set a **Chiyo connection password** for an uninitialized server, or enter its existing password. This is separate from the NAS system password.
4. Wait for the initial transfer. Different nonempty libraries are preserved rather than overwritten. Valid remembered connections are reused on later launches.

Make the first connection on a trusted LAN and check the address. A saved certificate or server identity is never silently replaced. The server stores a salted password verifier; the App stores a private connection token, not the password. Private certificate keys remain on the server. The server can decrypt information and must run on a trusted machine.

Change the connection password under **Settings → Storage & sync**. Other computers logged in with the old password must reconnect with the new one; this computer updates its connection automatically. AI uses a separate restricted identity and still requires approval.

For an older installation, update the server image while retaining the original `server.json`, data, keys, and TLS mounts. Existing App connections continue working. Set the first Chiyo connection password from a computer already connected to that server before connecting a new computer. An unauthenticated client cannot claim an existing library. Servers without the new setup API remain usable with saved connections, but need upgrading for password management.

In server-sync mode, the NAS receives requests and proposals. Local mode uses the service on this computer. Changing mode does not move old requests; existing chats retain their original service. See the [user guide (中文)](usage.md).

## Backups, upgrades, and migration

- Export a complete encrypted backup in the App and keep its recovery key separately. Verify recovery into an independent empty target.
- Before an upgrade, close the App and stop the service normally. Preserve data, `secrets`, connection configuration, and certificates. Do not reinitialize keys or overwrite a running database with a backup.
- When moving NAS storage, move the complete persistent directory and verify ownership and permissions. Reuse the original keys, server identity, and token.
- Follow the [operations guide (中文)](../apps/server/OPERATIONS.md) for a stopped copy, upgrade order, format compatibility, and rollback.

To stop the server:

```sh
docker compose -f deploy/compose.yaml stop -t 30
```

This stops the process without deleting mounted data. Confirm a normal exit before copying data or changing mounts.
