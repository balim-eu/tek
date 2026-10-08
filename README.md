# tek

Discover, install, and run **Tek architectures** — reusable, versioned project architectures published to Tek registries.

Get started in three steps:

1. [Install the tek CLI](#install).
2. [Add a registry](#registries) from the list below. tek ships without any registry.
3. Find and run architectures:

```bash
tek search
tek tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345
```

## Install

Linux and macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/balim-eu/tek/main/install.sh | sh
```

The installer downloads the binary for your system from the [latest GitHub release](https://github.com/balim-eu/tek/releases/latest), verifies it against the release's `SHA256SUMS`, and installs it to `~/.local/bin/tek`. If that directory is not on your `PATH`, it prints the line to add to your shell profile. Supported: Linux x64 and arm64, macOS Apple Silicon and Intel.

```bash
tek --version
```

Options: install a specific release with `... | sh -s -- 2026-10-06`, install elsewhere with `... | sudo env TEK_INSTALL_DIR=/usr/local/bin sh`, or use `wget -qO- <url> | sh` instead of `curl`. See also [manual install](#manual-install), [update](#update) and [uninstall](#uninstall).

## Registries

Add the registries you have access to. Each registry is added once; private registries need a token.

### balim-eu (private)

```bash
tek registry add balim-eu https://raw.githubusercontent.com/balim-eu/tek-registry/main/registry.json --token <token>
```

Replace `<token>` with a GitHub token that can read `balim-eu/tek-registry` — [how to get one](#get-a-token-for-balim-eu).

## Registry tokens

### Get a token for balim-eu

Anyone whose GitHub account can read [balim-eu/tek-registry](https://github.com/balim-eu/tek-registry) — normally members of the balim-eu organization — can create a token:

1. Open [GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token](https://github.com/settings/personal-access-tokens/new).
2. **Token name:** for example `tek registry`.
3. **Resource owner:** `balim-eu`. If it is not listed, your account is not a member of the organization.
4. **Expiration:** as long as your organization allows, for example 90 days.
5. **Repository access:** *Only select repositories* → `balim-eu/tek-registry`.
6. **Permissions → Repository permissions → Contents:** *Read-only*. (*Metadata: Read-only* is added automatically.) Nothing else is needed.
7. Click **Generate token** and copy it. It starts with `github_pat_`.
8. If the organization requires approval, the token stays *pending* until an organization owner approves it. Until then tek reports `ACCESS_DENIED`.

For organization owners: allow fine-grained tokens under **balim-eu → Settings → Personal access tokens**, and give members read access to `tek-registry`. For CI, store a token as a secret; the built-in `GITHUB_TOKEN` of a workflow cannot read other repositories.

### Add another registry

Any registry that serves a `registry.json` over HTTPS (or from a local path) can be added. Public registries need no token:

```bash
tek registry add company https://registry.company.com/registry.json
tek registry add company-private https://registry.company.com/private/registry.json --token <token>
```

## Usage

```text
tek search [query]                               Search configured registries
tek info <publisher/name@version>                Show details about an architecture
tek install <publisher/name@version>             Download, verify and install
tek list [publisher/name]                        List installed architectures
tek run <publisher/name@version> <command>       Run an architecture command
tek <publisher/name@version> <command>           Same as tek run
tek <publisher/name@version> --help              Show an architecture's commands
tek <publisher/name@version> --help-ai           Show an architecture's commands as Markdown for AI agents
tek <publisher/name@version> --version           Show an architecture's version
tek <publisher/name@version> prompt <task>       Print a prompt that starts an AI agent on a task
tek <publisher/name@version> <command> --help    Show a command's arguments and options
tek <publisher/name@version> <command> --help-ai Show a command's guide with examples as Markdown for AI agents
tek registry list                                List configured registries
tek registry add [name] <url> [--token <token>]  Add or update a registry
tek registry remove <name>                       Remove a registry
tek update [--pre-release] [--check]             Update tek itself
tek uninstall <publisher/name[@version]>         Remove an installed architecture
```

Every command has its own help, generated from the architecture's manifest. tek validates the arguments and options a command declares and checks its requirements (for example `flutter >=3.47.0`) before running it. Arguments after `--` are passed to the command unchanged. `--help-ai` prints the same reference as Markdown, after the guide the architecture ships for the command (its `helpAi` file), so an AI agent learns what the command does and how to call it in one step. Like `tek run`, it installs the architecture first when the command has a guide. For example:

```bash
tek tek/flutter-app create --help
tek tek/flutter-app create --help-ai
tek tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345 --languages en,de
tek tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345 --skip-setup
tek tek/flutter-app analyze my_app
tek tek/flutter-app fix my_app
```

`tek <architecture> prompt <task>` prints a prompt to start an AI agent with: the architecture's system prompt, how to work with it, in `<system_prompt>` tags and the task in `<user_prompt>` tags. Copy it into the agent, e.g. `tek tek/flutter-app prompt "Build a shop app with a cart" | pbcopy`, or pipe a longer task in with `tek tek/flutter-app prompt < task.md`.

`tek run` installs the architecture first if needed. To only use installed versions:

```bash
tek run --no-install tek/flutter-app@0.1.0 create my_app
```

### Installed architectures

```bash
tek list                               # everything installed, with versions and commands
tek list tek/flutter-app               # one architecture
tek uninstall tek/flutter-app          # every installed version
tek uninstall tek/flutter-app@0.1.0    # one version
tek uninstall tek/flutter-app@^0.1.0   # installed versions in a range
```

`tek uninstall` deletes the architecture's files from `~/.tek/architectures`; registries and tokens are kept.

### Versions

| Reference                    | Resolves to                          |
| ---------------------------- | ------------------------------------ |
| `tek/flutter-app@0.1.0`      | exactly `0.1.0`                      |
| `tek/flutter-app@0`          | latest `0.x.x`                       |
| `tek/flutter-app@0.1`        | latest `0.1.x`                       |
| `tek/flutter-app@^0.1.0`     | latest `>=0.1.0 <0.2.0`              |
| `tek/flutter-app@~0.1.2`     | latest `>=0.1.2 <0.2.0`              |
| `tek/flutter-app@latest`     | latest stable version                |
| `tek/flutter-app`            | same as `@latest`                    |

Installed architectures are always stored under their exact version.

### Multiple registries

When several registries are configured, they are searched in the order they were added and the first registry that contains an architecture is used. Pick one explicitly with `--registry`:

```bash
tek install acme/internal-api@2 --registry company
```

### Security

Architecture packages contain executable commands. `tek` downloads a package, verifies its SHA-256 checksum against the registry, validates its manifest and only then installs it. Before every run, the installed files are verified again; a modified installation is refused until it is reinstalled with `tek install <ref> --force`.

## JSON mode

Every command accepts `--json` for agents and scripts. JSON mode writes exactly one JSON document to stdout; progress and logs go to stderr.

```bash
tek search flutter --json
```

```json
{
  "ok": true,
  "query": "flutter",
  "architectures": [
    {
      "id": "tek/flutter-app",
      "publisher": "tek",
      "name": "flutter-app",
      "description": "A production-ready Flutter application architecture.",
      "registry": "balim-eu",
      "latest": "0.1.0",
      "versions": ["0.1.0"]
    }
  ]
}
```

Errors are machine-readable and the exit code is non-zero:

```json
{
  "ok": false,
  "error": {
    "code": "ARCHITECTURE_NOT_FOUND",
    "message": "Architecture acme/api@0.1.0 was not found."
  }
}
```

`tek run --json` returns the command's exit code and its stdout (parsed as JSON when possible) under `output`.

## Configuration

| Variable   | Default   | Purpose                                                                   |
| ---------- | --------- | ------------------------------------------------------------------------- |
| `TEK_HOME` | `~/.tek`  | Location of installed architectures, `config.json` and `credentials.json` |
| `NO_COLOR` | unset     | Set to any value to disable colors and spinners                           |
| `FORCE_COLOR` | unset  | Set to `1` to force colors, e.g. in CI logs                               |

## Manual install

Download the archive for your platform from the [releases page](https://github.com/balim-eu/tek/releases/latest), verify it and put the binary on your `PATH`:

```bash
curl -fsSLO https://github.com/balim-eu/tek/releases/latest/download/tek-linux-x64.tar.gz
curl -fsSLO https://github.com/balim-eu/tek/releases/latest/download/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
tar -xzf tek-linux-x64.tar.gz
mkdir -p ~/.local/bin
install -m 755 tek ~/.local/bin/tek
```

| Platform              | Archive                     |
| --------------------- | --------------------------- |
| Linux x64             | `tek-linux-x64.tar.gz`      |
| Linux arm64           | `tek-linux-arm64.tar.gz`    |
| macOS Apple Silicon   | `tek-macos-arm64.tar.gz`    |
| macOS Intel           | `tek-macos-x64.tar.gz`      |
| Windows x64           | `tek-windows-x64.zip`       |

On macOS use `shasum -a 256 -c SHA256SUMS --ignore-missing` instead of `sha256sum`.

## Update

```bash
tek update                 # latest release
tek update --pre-release   # latest pre-release
tek update --check         # only report whether an update is available
```

`tek update` downloads the build for your system, verifies it against the release's `SHA256SUMS`, checks that it starts, and only then replaces the binary it was run from. Registries, tokens and installed architectures are kept. Running the installer again works too.

### Release channels

| Channel     | Version             | Published                                                                              |
| ----------- | ------------------- | -------------------------------------------------------------------------------------- |
| pre-release | `YYYY-MM-DD-rc.N`   | on every push to `main` that changes the CLI; `N` counts up during the day              |
| release     | `YYYY-MM-DD`        | every night at 23:55 UTC, built from that day's latest pre-release; skipped without one |

A day's pre-releases are older than that day's release, so `tek update` moves you from `2026-10-07-rc.3` to `2026-10-07` once the nightly release is out, and never downgrades. Install a pre-release directly with `... | sh -s -- 2026-10-07-rc.3`.

## Files

tek only ever touches these paths:

| Path                                       | Written by                                    | Removed by                                  |
| ------------------------------------------ | --------------------------------------------- | ------------------------------------------- |
| `~/.local/bin/tek` (or `$TEK_INSTALL_DIR`) | install script, replaced by `tek update`      | you, see [Uninstall](#uninstall)            |
| `<same directory>/.tek.tmp`                | install script and `tek update`, while staging | right after staging, also on failure        |
| `~/.tek/architectures/<publisher>/<name>/` | `tek install`, `tek run`                      | `tek uninstall <publisher/name[@version]>`  |
| `~/.tek/tmp/`                              | `tek install`, while unpacking                | right after unpacking                       |
| `~/.tek/config.json`                       | `tek registry add`                            | `tek registry remove` (entries)             |
| `~/.tek/credentials.json`                  | `tek registry add --token`                    | `tek registry remove` (tokens)              |

Shell profiles are never modified; the installer only prints the `PATH` line to add.

## Uninstall

`tek uninstall` removes architectures, not tek itself. To remove tek, delete the binary and everything tek stored:

```bash
rm ~/.local/bin/tek
rm -rf ~/.tek
```

`~/.tek` holds installed architectures, registries and registry tokens. If tek is installed somewhere else, for example with `TEK_INSTALL_DIR=/usr/local/bin`, find it with `command -v tek` and remove that file instead (`sudo rm /usr/local/bin/tek`).

## Build from source

```bash
dart pub get
dart compile exe bin/tek.dart -o tek
```

## Development

`./dev` runs tek from source (`dart run bin/tek.dart`) against a local registry built from a tek-registry-sources checkout, without touching an installed tek or `~/.tek`. Use it like `tek`:

```bash
./dev search
./dev tek/flutter-app create my_app --name my_app --org com.example --development-team ABCDE12345
```

Everything happens in a workspace outside this repository, by default the `tek-dev` folder next to it: the tek home (`.home`), the built registry (`.registry`) and, when `./dev` is run from inside the tek or tek-registry-sources repository, the commands themselves, so `my_app` above ends up in `tek-dev/my_app`. Run from anywhere else, `./dev` works in the current directory like `tek`.

By default the registry sources are the `tek-registry-sources` folder next to this repository. Change `registry_repository` or `workspace` at the top of `dev`, or set `TEK_DEV_REGISTRY` and `TEK_DEV_WORKSPACE`. The registry is rebuilt when its architectures change, architectures with an executable are compiled for your machine with their `compile.sh` and cached by their sources, outdated installs are replaced automatically, and deleting the workspace starts over.
