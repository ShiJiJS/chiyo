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

Run the server on your own NAS or Linux host and connect over LAN HTTPS. You need Docker, Docker Compose, and OpenSSL. Run the following shell commands from the repository root and keep private data outside the checkout.

### 1. Prepare private storage

Replace the example bind address with the server's actual LAN address. The runtime user must own or have access to this new directory; on a NAS, use the UID/GID assigned to its data directory.

```sh
export CHIYO_STORAGE_DIRECTORY="$HOME/chiyo-data"
export CHIYO_BIND_ADDRESS="192.168.1.20"
export CHIYO_UID="$(id -u)"
export CHIYO_GID="$(id -g)"
export CHIYO_SOURCE_COMMIT="$(git rev-parse HEAD)"

umask 077
mkdir -p "$CHIYO_STORAGE_DIRECTORY/data" "$CHIYO_STORAGE_DIRECTORY/config" \
  "$CHIYO_STORAGE_DIRECTORY/tls" "$CHIYO_STORAGE_DIRECTORY/ca"
cp deploy/server.example.json "$CHIYO_STORAGE_DIRECTORY/config/server.json"
cp deploy/tls.example.cnf "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf"
```

Edit `[addresses]` in `ca/tls.cnf` to include the IP or DNS name you will enter in the App. The sample address is not valid for a different NAS. If you already have an appropriate certificate, place it and its private key at `tls/server.pem` and `tls/server.key`, then skip certificate generation.

### 2. Generate LAN certificates

These commands create a private CA and a server certificate. The CA private key stays in `ca/`, which is not mounted into the running server container.

```sh
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf" \
  -keyout "$CHIYO_STORAGE_DIRECTORY/ca/ca.key" \
  -out "$CHIYO_STORAGE_DIRECTORY/ca/ca.pem"

openssl req -new -newkey rsa:3072 -nodes \
  -subj "/CN=chiyo.local" \
  -keyout "$CHIYO_STORAGE_DIRECTORY/tls/server.key" \
  -out "$CHIYO_STORAGE_DIRECTORY/ca/server.csr"

openssl x509 -req -sha256 -days 825 \
  -in "$CHIYO_STORAGE_DIRECTORY/ca/server.csr" \
  -CA "$CHIYO_STORAGE_DIRECTORY/ca/ca.pem" \
  -CAkey "$CHIYO_STORAGE_DIRECTORY/ca/ca.key" -CAcreateserial \
  -extfile "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf" -extensions server \
  -out "$CHIYO_STORAGE_DIRECTORY/tls/server.pem"
```

The App only needs the public CA certificate, `ca/ca.pem`. Do not give it either private key. There is no need to change system-wide certificate trust.

### 3. Build and initialize

```sh
docker compose -f deploy/compose.yaml build

docker run --rm --user "$CHIYO_UID:$CHIYO_GID" \
  --mount "type=bind,source=$CHIYO_STORAGE_DIRECTORY,target=/setup" \
  chiyo-server:local init-secrets /setup/secrets

docker compose -f deploy/compose.yaml up -d
```

Initialization creates the database key, owner access token, and server identity. The `secrets` directory must not already exist; repeat initialization is rejected. Do not run it again for upgrades or restarts. Compose grants write access to `data` and mounts `config`, `secrets`, and `tls` read-only.

Check status and logs:

```sh
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail 50 chiyo
```

The container listens on port `47126`. Set `CHIYO_PORT` to change the host port. The bind address defaults to loopback; set `CHIYO_BIND_ADDRESS` as above for LAN access. Reuse the same environment values and private directory for maintenance. You may keep them in your own environment configuration, but do not commit real deployment configuration or keys.

`readCacheMiB` in `server.json` is a database read-cache budget: default 128 MiB, range 32–512, applied on restart. It is not a whole-process memory limit and does not preload all attachments.

## Connect the App

1. Open **Settings → Storage & sync** and select **Server sync**.
2. Enter `https://actual-lan-address:47126` and the owner access token.
3. If using the private CA above, paste the complete contents of `ca/ca.pem` into the server certificate field.
4. Select **Connect and enable sync** and wait for the initial transfer. Different nonempty libraries are not overwritten automatically; back them up and select an empty target when prompted.

Convert the token in your own trusted terminal, then enter it in the App:

```sh
openssl base64 -A -in "$CHIYO_STORAGE_DIRECTORY/secrets/owner.token" \
  | tr '/+' '_-' | tr -d '='
```

This is the **App's owner management token**. Do not give it to the AI or put it in ordinary logs. The App automatically prepares a restricted Agent connection; the CLI does not need the management token. The server can decrypt information and must run on a trusted machine.

In server-sync mode, the NAS receives requests and proposals, and the App reviews them there. Local mode uses the service on this computer. Switching modes does not move old requests; existing chats retain their original service. See the [user guide (中文)](usage.md).

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
