# tek

Install and run **tek architectures**: versioned project architectures from tek registries.

## Getting started

### 1. Install tek

Linux and macOS:

```bash
# latest release
curl -fsSL https://raw.githubusercontent.com/balim-eu/tek/main/install.sh | sh
# latest pre-release
curl -fsSL https://raw.githubusercontent.com/balim-eu/tek/main/install.sh | sh -s -- pre-release
# a specific release or pre-release
curl -fsSL https://raw.githubusercontent.com/balim-eu/tek/main/install.sh | sh -s -- 2026-10-08
curl -fsSL https://raw.githubusercontent.com/balim-eu/tek/main/install.sh | sh -s -- 2026-10-08-rc.1
```

Windows (PowerShell):

```powershell
# latest release
irm https://raw.githubusercontent.com/balim-eu/tek/main/install.ps1 | iex
# latest pre-release
irm https://raw.githubusercontent.com/balim-eu/tek/main/install-pre-release.ps1 | iex
# a specific release or pre-release
$env:TEK_VERSION = '2026-10-08'; irm https://raw.githubusercontent.com/balim-eu/tek/main/install.ps1 | iex
$env:TEK_VERSION = '2026-10-08-rc.1'; irm https://raw.githubusercontent.com/balim-eu/tek/main/install.ps1 | iex
```

Every version is listed on the [releases page](https://github.com/balim-eu/tek/releases).

### 2. Add a registry

```bash
tek registry add balim-eu https://raw.githubusercontent.com/balim-eu/tek-registry/main/registry.json
```

tek asks for a token or a username and password when the registry needs one. See [registries](#registries) for the available registries.

### 3. Set an architecture up and create a project

```bash
tek search
tek tek/flutter-app install-tools                  # the software it needs, e.g. Flutter with fvm, melos, Chrome
tek tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345
cd my_app && tek setup                             # the project's dependencies, generated code
```

`install-tools` installs what is missing on this machine with the system's package manager or the vendor's installer, on macOS and Linux, and makes it visible to new shells. `create` writes the files and the project's `tek.yaml`, its `name` and the `architecture` it was made with, which `tek setup` reads, also in a fresh clone; a project of several products lists their folders under `products`.

## Registries

| Name       | URL                                                                          | Access                         |
| ---------- | ---------------------------------------------------------------------------- | ------------------------------ |
| `balim-eu` | `https://raw.githubusercontent.com/balim-eu/tek-registry/main/registry.json` | [token](#token-for-balim-eu)   |

More registries are coming. Any `registry.json` served over HTTPS or from a local path can be added with `tek registry add <name> <url>`.

### Token for balim-eu

[Create a fine-grained token](https://github.com/settings/personal-access-tokens/new):

- **Resource owner:** `balim-eu`. If it is not listed, your account is not a member of the organization.
- **Repository access:** only `balim-eu/tek-registry`
- **Permissions:** Contents: Read-only

The token starts with `github_pat_`. If the organization requires approval, tek reports `ACCESS_DENIED` until an owner approves it. When it expires, save a new one with `tek registry login balim-eu`.

## Commands

```text
tek search [query]                               List the architectures, or those whose name contains the query
tek info <architecture>                          Show details about an architecture
tek install <architecture>...                    Download, verify and install one or more architectures
tek list [publisher/name] [--pre-release]        List installed architectures and their updates
tek upgrade [publisher/name...] [--pre-release]  Upgrade installed architectures to their latest version
tek uninstall <architecture>...                  Remove installed architectures, their tools stay
tek <architecture> <command>                     Run a command, same as tek run
tek <architecture> --help                        Show the commands of an architecture
tek <architecture> <command> --help              Show the arguments and options of a command
tek <architecture> --help-ai                     Same as Markdown for AI agents
tek <architecture> <command> --help-ai           Same as Markdown, with the command's guide and examples
tek <architecture> doctor                        Check the software an architecture needs
tek <architecture> install-tools                 Install the software it needs that is missing, asking once
tek setup [directory]                            Set a project up with the architecture of its tek.yaml
tek shellenv [zsh|bash|sh|fish|pwsh|dockerfile]  Print PATH and the variables of the tools tek installed
tek path [--remove]                              List PATH by tek, system and yours, or undo tek's changes
tek <architecture> --version                     Show the version of an architecture
tek registry list                                List the configured registries
tek registry add [name] <url>                    Add or update a registry, asks for credentials if needed
tek registry login <name>                        Save new credentials, e.g. after a token expired
tek registry logout <name>                       Remove the saved credentials
tek registry remove <name>                       Remove a registry and its credentials
tek update [--pre-release] [--check]             Update tek itself
```

- `tek search` lists every architecture of the configured registries with its latest version and what it is, `tek search <query>` only those whose name contains the query, ignoring case, e.g. `tek search api` or `tek search tek/flutter`. `tek info <architecture>` shows its versions and commands.
- `tek run` installs the architecture first when needed, `--no-install` only uses installed versions.
- `tek list` shows every installed architecture with its installed versions, newest first, the registry and the day it was installed. It checks the registry each architecture was installed from for a newer version than the newest installed one: releases only, also release candidates (`-rc.N`) with `--pre-release`. `--offline` skips the check.
- `tek upgrade` installs that newer version of every installed architecture, or of the ones it names, from the same registry: releases only, also release candidates with `--pre-release`, never a downgrade. The older versions stay installed for projects that pin them, `tek uninstall <publisher/name@version>` removes one. Without `@version`, `tek <architecture>` runs the newest installed release, a release candidate only with `@<version>`.
- `doctor` exits with 1 when something required is missing. Every command checks what it needs first and names `install-tools` when something is missing.
- `install-tools` takes `--with <target|tool>` for optional tools, e.g. `--with android,ios`, `--optional` for all of them, `--yes` to install without asking and `--dry-run` to print the steps for this machine. It installs the architecture first when it isn't installed.
- Architectures can print prompts for AI agents, ready to paste, e.g. `tek tek/flutter-app prompt-create-app "Build a shop app" | pbcopy`.
- Arguments after `--` are passed to the command unchanged.
- Every command accepts `--json`.

### Versions

| Reference                | Resolves to                   |
| ------------------------ | ----------------------------- |
| `tek/flutter-app`        | latest stable version         |
| `tek/flutter-app@0.1.0`  | exactly `0.1.0`               |
| `tek/flutter-app@0.1`    | latest `0.1.x`                |
| `tek/flutter-app@^0.1.0` | latest `>=0.1.0 <0.2.0`       |
| `tek/flutter-app@~0.1.2` | latest `>=0.1.2 <0.2.0`       |

With several registries, the first one added that has the architecture is used. Pick one with `--registry <name>`.

## Update

```bash
tek update                 # latest release
tek update --pre-release   # latest pre-release
tek update --check         # only check for an update
```

| Channel     | Version           | Published                                                          |
| ----------- | ----------------- | ------------------------------------------------------------------ |
| pre-release | `YYYY-MM-DD-rc.N` | on every push to `main` that changes the CLI                       |
| release     | `YYYY-MM-DD`      | every night at 23:55 UTC from that day's latest pre-release, if any |

`tek update` never downgrades: `2026-10-07-rc.3` updates to `2026-10-07` once that release is out.

## Uninstall

```bash
rm ~/.local/bin/tek
rm -rf ~/.tek
```

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\tek", "$env:USERPROFILE\.tek"
```

On Windows, also remove `%LOCALAPPDATA%\tek\bin` from your user `PATH`.

## Technical details

### Installer

The installer downloads the build for your system from the GitHub release, verifies it against the release's `SHA256SUMS` and installs it to `~/.local/bin/tek`, on Windows `%LOCALAPPDATA%\tek\bin\tek.exe`. On Linux and macOS it prints the line to add to your shell profile when that directory is not on your `PATH`; on Windows it adds the directory to your user `PATH`. Set `TEK_INSTALL_DIR` to install elsewhere.

Supported: Linux x64 and arm64, macOS Apple Silicon and Intel, Windows x64.

To install by hand, download `tek-<os>-<arch>.tar.gz` (Windows: `tek-windows-x64.zip`) and `SHA256SUMS` from the [releases page](https://github.com/balim-eu/tek/releases), check the checksum and put `tek` on your `PATH`.

### Registry credentials

A registry is public, or needs a token (sent as `Authorization: Bearer`) or a username and password (sent as `Authorization: Basic`). Its `registry.json` describes which one, what it is for and where to get it, and tek shows that when it asks for credentials or when they are rejected.

```bash
tek registry add <name> <url> --token github_pat_xxx
tek registry add <name> <url> --token -                        # hidden prompt, or read from stdin
tek registry add <name> <url> --username me --password -
```

Without these options, tek asks in an interactive terminal. In scripts, CI and with `--json` it never asks and fails with `AUTHENTICATION_REQUIRED` and a hint instead. For CI, set `TEK_REGISTRY_<NAME>_TOKEN`, or `TEK_REGISTRY_<NAME>_USERNAME` and `TEK_REGISTRY_<NAME>_PASSWORD` (`balim-eu` → `TEK_REGISTRY_BALIM_EU_TOKEN`). They take precedence over saved credentials and are never written to disk. Credentials are only sent over HTTPS, to the registry's host and the hosts its `registry.json` lists.

### Security

Every architecture is one compiled executable per platform. tek downloads the one for your system, verifies its SHA-256 checksum against the registry and validates the manifest before installing it. Before every run the installation is verified again; a modified one is refused until `tek install <architecture> --force`.

### JSON mode

With `--json`, tek writes exactly one JSON document to stdout and logs to stderr. Errors come as `{"ok": false, "error": {"code": "ARCHITECTURE_NOT_FOUND", "message": "..."}}` with a non-zero exit code. `tek run --json` returns the command's exit code and its output under `output`.

### Configuration

| Variable      | Default  | Purpose                                                        |
| ------------- | -------- | -------------------------------------------------------------- |
| `TEK_HOME`    | `~/.tek` | Installed architectures, `config.json` and `credentials.json`  |
| `NO_COLOR`    | unset    | Disable colors and spinners                                    |
| `FORCE_COLOR` | unset    | Set to `1` to force colors, e.g. in CI logs                    |

On Windows, `~` is `%USERPROFILE%`.

### Files

| Path                                          | Written by                                | Removed by                    |
| --------------------------------------------- | ----------------------------------------- | ----------------------------- |
| `~/.local/bin/tek`, Windows `%LOCALAPPDATA%\tek\bin\tek.exe` | installer, `tek update`    | you, see [Uninstall](#uninstall) |
| `~/.tek/architectures/<publisher>/<name>/`    | `tek install`, `tek run`                  | `tek uninstall`               |
| `~/.tek/config.json`                          | `tek registry add`                        | `tek registry remove`         |
| `~/.tek/credentials.json`                     | `tek registry add`, `tek registry login`  | `tek registry logout`, `tek registry remove` |
| `~/.tek/tmp/`, `.tek.tmp` next to the binary  | `tek install`, installer, `tek update`    | right after use               |

| `~/.tek/tools.json`                           | the registry's tools, cached by `tek install`, `install-tools` | you |
| `~/.tek/path.json`                            | `install-tools`, the folders and variables it made visible | `tek path --remove` |
| one line in `~/.zshrc`, `~/.bashrc`, `~/.profile`, `~/.bash_profile` | `install-tools`, when a tool's folder isn't on PATH | `tek path --remove` |
| links in `/usr/local/bin`, `/etc/profile.d/tek.sh` | `install-tools` as root               | `tek path --remove`           |

### Tools

An architecture's manifest names the tools it needs in `runtime`, required ones and optional ones by target; the registry's `tools/<name>.yaml` describes how each installs on every system: Homebrew on macOS, apt on Ubuntu and Debian, dnf on Amazon Linux and the RHEL family, or the vendor's repository or installer. tek prepares the system first, Homebrew on macOS and the base packages on Linux, runs the steps that need root directly as root or through sudo, and checks every tool after its last step.

A tool whose folder isn't on PATH, e.g. `~/.cargo/bin`, goes into `~/.tek/path.json`, and tek writes one line into the shell profiles, `[ -x "$HOME/.local/bin/tek" ] && eval "$("$HOME/.local/bin/tek" shellenv)"`, which adds the recorded folders after yours. As root it links the programs into `/usr/local/bin` instead; in GitHub Actions it appends to `$GITHUB_PATH` and `$GITHUB_ENV`. tek's own commands see every tool right away. In a Dockerfile, `RUN tek <architecture> install-tools --yes`, then `tek shellenv dockerfile` prints the `ENV` lines.

Supported: macOS 15 and later, Ubuntu 22.04 and 24.04, Debian 12 and 13, Amazon Linux 2023, each on x64 and arm64; Windows through WSL2 with Ubuntu. Xcode asks for an Apple ID once, as Apple requires.

## Development

```bash
dart pub get
dart compile exe bin/tek.dart -o tek
```

`./dev` runs tek from source against a local registry built from the `tek-registry-sources` folder next to this repository, in a workspace outside it (`../tek-dev`), without touching an installed tek or `~/.tek`:

```bash
./dev search
./dev tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345
```

Architectures are compiled for your machine and cached by their sources. Set `TEK_DEV_REGISTRY` and `TEK_DEV_WORKSPACE` to use other folders.
