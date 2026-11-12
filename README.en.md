<h1 align="center">知予 · chiyo</h1>
<p align="center"><img src="apps/desktop/assets/branding/chiyo-icon.png" alt="Chiyo icon" width="160" /></p>
<p align="center">Keep your information organized. Let AI request what it needs. You decide.</p>
<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>
<p align="center"><a href="https://github.com/ShiJiJS/chiyo/releases">Downloads</a> · <a href="docs/deployment.en.md">Installation & deployment</a> · <a href="docs/usage.md">User guide (中文)</a> · <a href="docs/README.md">Documentation</a> · <a href="https://github.com/ShiJiJS/chiyo/issues">Issues</a></p>

Chiyo is a **personal information manager with approval-based AI access**. Keep documents, personal profiles, server details, and account credentials together. When an AI needs information, it submits a request; you review its purpose and choose what to share in the desktop App.

You can also give the AI a set of files to organize into an import proposal using the available templates. Preview new information, compare changes, and enter any required passwords in the proposal before saving the whole proposal together.

## Features

- **Organize information:** folders, tags, links, drag-and-drop moves, and batch recycling; Markdown, images, PDFs, attachments, and retained versions.
- **Manage credentials:** store passwords, tokens, and key files against the relevant accounts and services. Approved use happens through programs on the AI's own computer.
- **Review AI requests:** inspect purpose, chat identity, selected fields or file versions, and duration; review history and revoke further access.
- **Use locally or sync with your NAS:** run independently or synchronize with a self-hosted server. Conflicting edits retain both candidates for you to review.
- **Back up and extend:** encrypted backups with a separate recovery key, plus template plugins that provide fields, instructions, and examples.

## Getting started

1. Get the appropriate development package from [Releases](https://github.com/ShiJiJS/chiyo/releases) and follow the [installation guide](docs/deployment.en.md).
2. On first launch, choose **Local use** or **Server sync**. Enter the server IP/domain and port, then set or enter its Chiyo connection password. Certificate setup is automatic.
3. Add information manually, or configure the bundled CLI and Skill using the matching integration instructions so the AI can submit proposals.
4. Review proposals and fill in missing passwords in the App. Handle AI access requests under **Access approvals**.

The source supports **macOS 14+ on Apple Silicon** and **Windows x64**. This is a development preview. The release page currently offers an earlier Mac package; Windows adaptation and the latest features are in `main` and can be [built from source](docs/development/README.md). Check each release's actual attachments and manifest for its version and platform. The current App interface is in Chinese.

### Two modes

| | Local mode | Server sync |
| --- | --- | --- |
| Information | Encrypted on this computer | An encrypted local replica synchronized with your NAS |
| Requests, proposals, and approvals | Handled by the local service while the App is running | Received by the NAS and reviewed in the App |
| Network | No NAS required | Server approvals and synchronization require a connection |

Changing mode does not move old requests or copy active chat permissions. New chats use the selected mode; existing chats retain their original connection. Switch back to that mode to handle their requests. See the [user guide (中文)](docs/usage.md).

## Components

| Component | Purpose |
| --- | --- |
| **App** | Manage information, review proposals and requests, and inspect history |
| **CLI** | Let AI discover the catalog and live templates, submit proposals and access requests, and use approved information |
| **Skill** | Explain how the AI should use the CLI; available templates and examples come from the running software |
| **Server** | Optional Docker deployment on your NAS or Linux host; stores synchronized information and receives requests independently |

The CLI and Skill are included in development packages. Follow the [AI integration guide (中文)](integrations/codex/README.md). A Skill does not grant access, and an Agent device credential does not provide owner management privileges.

## Data storage

Information is encrypted with SQLCipher. Local database keys are protected by macOS Keychain or Windows DPAPI; the server uses its own persistent keys. The server can decrypt information, so deploy it on a machine you trust.

Keep encrypted backups and recovery keys separately. See [installation and deployment](docs/deployment.en.md) and [server operations (中文)](apps/server/OPERATIONS.md) for upgrades, migration, and recovery.

## Documentation and development

- [Installation, Docker deployment, and connection](docs/deployment.en.md) · [简体中文](docs/deployment.md)
- [Information, proposals, approvals, and sync (中文)](docs/usage.md)
- [AI / Codex integration (中文)](integrations/codex/README.md) · [CLI reference (中文)](docs/cli.md)
- [Development and repository layout (中文)](docs/development/README.md) · [Documentation index](docs/README.md)

Report problems and feature requests through [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues).
