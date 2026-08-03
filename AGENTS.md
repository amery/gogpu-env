# Agent Development Guide

Technical implementation details for AI agents and developers working with
this codebase. For general setup instructions, see [README.md](./README.md).

**IMPORTANT**: When making changes to the DevContainer setup, initialisation
process, or mount configuration, you MUST update both AGENTS.md and README.md
to reflect the changes before committing. This ensures documentation stays
accurate and synchronised.

## Quick Reference

- **Container Home**: `.docker-run-cache/${HOME}`
- **Config Mounts**: `~/.claude/` and `~/.claude.json` from host
- **Init Script**: `.devcontainer/init.sh` (runs on host before container)
- **Key Files**: `devcontainer.json`, `docker/Dockerfile`, `run.sh`
- **Base Image**: `docker-apptly-builder` (Ubuntu + VS Code + Go + Node.js)
- **Execution Modes**: DevContainer (long-lived) and `x` (per-command)
- **Trampoline**: `x` → `run.sh` → docker-builder-run → container
- **Passthrough**: `run.sh` detects `/.dockerenv` and skips docker
- **Host Alias**: container reaches host as `host.docker.internal`
- **GPU**: host render nodes exposed per kernel driver, via
  `docker/gpu.sh`

## Dual Execution Architecture

This project supports two complementary execution modes, both using the
same base image and entrypoint for consistent behaviour:

### DevContainer Mode (Long-Lived)

VS Code manages a persistent container with integrated terminal and
debugging:

- **Lifecycle**: Started by VS Code, runs until stopped
- **Entry**: VS Code executes container directly
- **Terminal**: Opens shells inside running container
- **User Setup**: Entrypoint creates user matching host UID/GID
- **Use Case**: Interactive development with IDE features

### CLI Mode via `x` (Per-Command)

The `x` helper trampolines commands through `docker-builder-run`
on the host:

- **Lifecycle**: Fresh container per command invocation
- **Entry**: `x` → `run.sh` → docker-builder-run → container
- **Terminal**: Command executes, container terminates
- **User Setup**: Same entrypoint, same UID/GID matching
- **Use Case**: Host-side builds, CI/CD, nested workspaces
- **Script Portability**: Scripts never include `x`; use `x ./script.sh`
  from host
- **Container-Aware**: `run.sh` detects `/.dockerenv` and passes
  through directly, so `x` also works inside the container

Both modes converge at the container entrypoint, which handles user
creation, environment setup, and directory navigation (CURDIR). This
ensures `./script.sh` in DevContainer terminal behaves identically to
`x ./script.sh` from host.

## DevContainer Architecture

VS Code DevContainers with custom sandboxed home directory approach
provide isolated development environments whilst preserving access to
essential host resources.

### Security Configuration

The DevContainer runs with elevated privileges to enable advanced development
scenarios:

- **`NET_ADMIN`**: Network administration for debugging network configurations
- **`SYS_PTRACE`**: Process tracing for debugging tools (gdb, strace)
- **AppArmor Unconfined**: Disabled AppArmor restrictions
- **Seccomp Unconfined**: Unrestricted system calls

**WARNING**: These settings significantly reduce container security. This
configuration is intended ONLY for trusted development environments, not for
production use.

### Foundation: docker-builder

This project builds upon
[amery/docker-builder](https://github.com/amery/docker-builder), which
provides:

- **Base Images**: The `docker-apptly-builder` image used as foundation
- **Run Script**: `docker-builder-run` for container execution
- **Build System**: Automated Docker image building and management

See the [docker-builder documentation][docker-builder-agent]
for details on the underlying infrastructure.

### Sandboxed Home Directory

The container uses `.docker-run-cache/${HOME}` as an isolated home directory:

- Prevents container modifications from affecting the host home directory
- Maintains clean separation between host and container environments
- Allows persistence of container-specific configurations

### Bind Mount Strategy

The devcontainer selectively shares resources between host and container:

1. **Workspace**: Mounted at the same path as on host for consistency
2. **Sandboxed Home**: Container home at `.docker-run-cache/${HOME}`
3. **Tool Configs**: Specific directories bind-mounted from host:
   - `~/.claude` directory for Claude AI configuration persistence
   - `~/.claude.json` for Claude AI state persistence
4. **GPG Agent Socket**: Conditionally bind-mounted from host for
   commit signing:
   - Socket directory at `$XDG_RUNTIME_DIR/gnupg` (falls back to
     `/run/user/$(id -u)/gnupg`)
   - Only mounted when the directory exists on the host
   - Enables GPG signing inside the container using the host's
     gpg-agent (runs in restricted mode across namespaces)
   - Container needs public keys imported (`gpg --import ~/.gnupg/*.asc`)

Both execution modes provide these tool config and GPG socket
mounts — the DevContainer via devcontainer.json, and CLI mode via
`run.sh`. This ensures AI assistants and signing tools have
consistent access to their configuration regardless of how the
container is launched.

### Host Access from the Container

Both execution modes add `--add-host=host.docker.internal:host-gateway`
— the DevContainer via devcontainer.json, CLI mode via `run.sh`. Docker
resolves the `host-gateway` sentinel at container start and writes
the bridge gateway IP into `/etc/hosts`, so containers reach the
host as `host.docker.internal` regardless of the bridge's IP. This
replaces the brittle pattern of hard-coding `172.17.0.1`.

For workflows that drive a host-side tool from inside the container
(e.g. `chrome-devtools-mcp` tunnelling to a visible Chrome on the
host), use this alias.

#### Local LLM access (Ollama)

The image bakes `/etc/profile.d/ollama.sh` (see `docker/Dockerfile`), so
login shells point CLI clients — Ollama's own client and srclight's
embedding backend — at a host Ollama daemon on
`host.docker.internal:11434`. It is a silent no-op when the alias does
not resolve or the variables are already set. Like the SSH path, it
relies on the host daemon being reachable over `docker0`: Ollama
listening on the bridge (or all interfaces) and the host firewall
permitting `docker0` → port 11434. The variables set are listed under
[Environment Variables](./README.md#environment-variables) in README.md.

#### Host-side prerequisites

- **`sshd` must listen on the bridge interface** for SSH-from-container
  workflows. The default `ListenAddress 0.0.0.0` accepts connections
  from `docker0`. Hardened configurations narrowed to `127.0.0.1` will
  reject the container.
- **Host firewall must allow `docker0` → host services.** On ufw, for
  SSH:

  ```bash
  sudo ufw allow in on docker0 to any port 22 proto tcp
  ```

  On nftables/iptables, add an `ACCEPT` in the `INPUT` chain for
  `-i docker0 -p tcp --dport <port>`.

#### Rootless Docker caveat

On rootless Docker the `host-gateway` sentinel resolves to `0.0.0.0`
unless `dockerd` is started with `--host-gateway-ip=<ip>` (or the
equivalent in `/etc/docker/daemon.json`). Docker Desktop on
macOS/Windows pre-wires `host.docker.internal` independently, so the
spelling stays uniform there.

#### DNS staleness on the default bridge

Docker copies the host's `/etc/resolv.conf` into the container at
start time and marks it `(legacy)`. Those addresses then go stale
when the host moves between networks (e.g. a laptop leaving a LAN
whose gateway DNS was a private IP). Set static resolvers in
`/etc/docker/daemon.json` to avoid this:

```json
{ "dns": ["1.1.1.1", "1.0.0.1"] }
```

Restart the Docker daemon after the change. Containers then receive
the configured resolvers regardless of the host's current network.
Choose resolvers reachable from every network the host might join —
an internal-only resolver would re-create the problem.

#### Verification

From inside a container:

```bash
getent hosts host.docker.internal
ssh -o BatchMode=yes -o ConnectTimeout=5 host.docker.internal true
```

`Permission denied (publickey)` from the SSH probe confirms the TCP
path reached `sshd`; only auth remains (mount `~/.ssh` or forward
the agent via `$SSH_AUTH_SOCK`).

## GPU Passthrough

Both execution modes expose the host GPUs to the webgpu (Vulkan)
backend. The discrimination and the render-node inventory live in
`docker/gpu.sh`, sourced by `docker/run.sh` for CLI mode and by
`.devcontainer/init.sh` for DevContainer mode; each shapes the result
into the form its launcher takes — a flat `DOCKER_EXTRA_OPTS` string on
one side, `runArgs` tokens on the other.

### Driver Discrimination

The discriminator is the kernel driver bound to the render node, read
from `/sys/class/drm/<node>/device/driver` — not the "open versus
proprietary" label:

- **Mesa drivers** (`i915`, `xe`, `amdgpu`, `nouveau`, …): the
  `/dev/dri` render node is passed through with `--device` and the
  in-image Mesa Vulkan stack (anv, radv, NVK) drives it
- **`nvidia`**, proprietary *or* NVIDIA's open kernel modules: the
  render node is skipped, because it yields no Vulkan device — the
  access path is the NVIDIA userspace ICD via `/dev/nvidia*`, and Mesa
  NVK binds only nouveau. The GPU is reached through the NVIDIA
  Container Toolkit instead (`--gpus all`, plus
  `NVIDIA_DRIVER_CAPABILITIES=all` for the `graphics` capability the
  toolkit otherwise withholds), and only when `nvidia-ctk` is present
  on the host; without it the request is dropped rather than failing
  the run

A GPU-less host adds nothing: the glob stays literal and every
candidate fails the device test.

### Group Membership

A passed-through render node is owned by a host gid with no matching
container group. The workspace user cannot open it unaided, and a gid
that resolves to no name is upsetting in its own right — everything
that reports group membership shows the bare number. The
`15-gpu-render.sh` entrypoint plugin answers both: create or reuse a
**named** group with the node's gid, then enrol the user. Each mode
runs it at the point where it still has root:

- **CLI**: the entrypoint sources the plugin at container start with
  the device attached, so the gid is read from `/dev/dri`; the later
  `su -` inherits the group
- **DevContainer**: there is no root phase at runtime — the user is
  PID 1 and VS Code overrides the entrypoint — so the group is baked
  into the image instead. `gen_dockerfile` appends a build step
  running the same plugin, with the host's gids in `GPU_RENDER_GIDS`
  because a build has no device to read them from. The image's
  `/etc/group` carries the named group, and the container starts with
  it in the user's credentials

Two details of that build step are load-bearing. It is emitted after
`/devcontainer-init.sh`, which is where the workspace user gets its
final name — before that it is still `vscode`. And the gids travel on
that one `RUN` rather than as an `ENV`, so the plugin stays a no-op
when `gen_profile` sources it during the earlier step.

`runArgs` therefore carries only the device; a build cannot attach
one. It is regenerated in full on every init and merged with replace
semantics, so re-runs stay idempotent instead of accumulating duplicate
`--device` entries. On a host with a GPU the regenerated array differs
from the committed baseline; that difference is host-specific and is
not meant to be committed.

Device and capability requirements would ideally travel with the image
in a `run-hook.sh`, which is where docker-builder's design puts them.
That mechanism is image-distributed — the workspace copy is extracted
from the image and overwritten on mismatch — so adopting it means
shipping the hook from docker-builder rather than authoring one here.
Until then this stays in `run.sh` and `init.sh`.

### Diagnostics

From inside a container:

```bash
vulkaninfo --summary   # Vulkan ICDs and devices
```

## How Initialisation Works

The initialisation provides cross-platform flexibility through a Node.js
entry point that detects the OS and runs platform-specific scripts:

### Execution Context

- **When**: Triggered by VS Code via `initializeCommand` before container
  creation
- **Where**: Runs on the host machine (not in container)
- **Entry**: `node .devcontainer/init.js` detects OS and runs appropriate
  script
- **Requirements**: Node.js (for init.js) and Docker access. The base
  image metadata is read via `docker inspect`; the first run pulls the
  image if it is not present locally, so network access is needed once

Key functions in platform scripts:

- `get_base_image`: Parses the last `FROM` line from `docker/Dockerfile`
- `may_pull_image`: Pulls the base image when it is not present locally
  (`docker inspect` only sees local images), so its metadata label is
  readable instead of silently lost; fails loudly if the pull fails
- `get_metadata` / `metadata`: Read the base image's metadata label and
  append the `containerUser` entry
- `gen_dockerfile`: Extends base Dockerfile with user metadata
  - Uses `containerUser` in metadata label (not `remoteUser`)
  - Removes verbose shell execution (`sh` instead of `sh -x`)
  - Appends the GPU render group build step when `gen_gpu_gids` finds
    a passed-through node (see [Group Membership](#group-membership))
- `gen_json_overlay`: Creates mount configuration including:
  - Sandboxed home directory mount
  - Claude directory bind mount
  - Claude JSON file bind mount
  - GPG agent socket bind mount (conditional)
- `json_sanitize`: Strips comments from JSONC files with validation
- `json_merge`: Merges JSON configurations with 2-space formatting
- `rename`: Atomic file updates to avoid race conditions

### Step-by-Step Process

#### Common Steps (All Platforms)

1. **OS Detection** (init.js):
   - Uses `process.platform` to detect Windows (`win32`) vs Unix
   - Launches platform-specific script with appropriate interpreter

2. **Environment Setup**:
   - Navigate to project root
   - Set up directory variables:
     - `B=".devcontainer"` - DevContainer directory
     - `C=".docker-run-cache"` - Cache directory for mounts

3. **Dockerfile Generation**:
   - Reads `docker/Dockerfile` as the base
   - Resolves the base image from the last `FROM` line, pulling it if not
     present locally, then reads its metadata with `docker inspect`
   - Appends user-specific configuration:
     - Runs `/devcontainer-init.sh` with username and home path
     - Enrols that user in the host's GPU render group, when there is
       one
     - Sets container user to match host user
     - Adds devcontainer metadata label with `containerUser` field
   - **Platform differences**:
     - Linux/macOS: Uses `$HOME` directly
     - Windows: Translates paths (see Windows-specific section)

4. **JSON Configuration Merge**:
   - **Step 1**: Sanitise existing `devcontainer.json` (remove comments)
   - **Step 2**: Generate overlay with mount configurations
   - **Step 3**: Merge overlay with existing config (overlay wins)
   - **Step 4**: Write result with 2-space indentation
   - **Platform differences**:
     - Linux/macOS: Uses `${localEnv:HOME}` for paths
     - Windows: Uses `${localEnv:USERPROFILE}` with path translation

5. **Mount Point Preparation**:
   - Creates isolated container home: `${C}${HOME}` (or
     `${C}${USERPROFILE}` on Windows); `$HOME` includes leading slash, so
     becomes `.docker-run-cache/home/username`
   - Creates host-bound directories in both locations:
     - `$PWD` (current directory)
     - `~/.claude` (AI config directory; `$USERPROFILE/.claude` on
       Windows)
   - Handles host-bound files:
     - `~/.claude.json`: touched in cache, initialised with `{}` on host
       if empty
   - Uses case pattern to handle JSON files specially

### Platform-Specific Details

#### Windows (init.ps1)

- **Username Sanitisation**: Windows usernames may contain spaces or special
  characters
  - Replaces invalid characters with underscores
  - Prepends underscore if starting with number
  - Converts to lowercase for Linux compatibility
- **Path Translation**: Converts Windows paths to container paths
  - Detects Docker backend (WSL vs Docker Desktop)
  - WSL format: `C:\Users\john` → `/mnt/c/users/john`
  - Docker Desktop: `C:\Users\john` → `/C/Users/john`
  - Applied to both workspace and home directories
- **Environment Variables**:
  - Uses `$env:USERNAME` and `$env:USERPROFILE`
  - Translates to Linux equivalents for container

#### Linux/macOS (init.sh)

- **Direct Path Usage**: Native paths work without translation
- **macOS Specifics**:
  - Checks for Docker socket in multiple locations
  - Requires Homebrew and jq installation
- **Environment Variables**: Uses standard `$HOME` and `$USER`

### Key Design Decisions

- **Cross-Platform Entry**: Node.js provides consistent OS detection
- **Atomic Updates**: Uses temp files + rename to avoid partial writes
- **Idempotent**: Can run multiple times safely
- **Non-Destructive**: Only updates files if they differ
- **Error Handling**: Strict error checking (Bash `set -eu`, PowerShell
  `$ErrorActionPreference`)

### File Flow Diagram

```text
                    init.js (Node.js)
                         ↓
              ┌──────────┴──────────┐
              │                     │
         Windows               Unix/Linux/macOS
              │                     │
         init.ps1              init.sh
              │                     │
              └──────────┬──────────┘
                         ↓
docker/Dockerfile → gen_dockerfile → .devcontainer/Dockerfile
                         ↓
                  (adds user metadata)

devcontainer.json → json_sanitize → clean JSON
                         ↓
gen_json_overlay → mount config → json_merge → updated devcontainer.json
                         ↓
                 (platform-specific paths)
```

## The `x` Command Architecture

The `x` helper provides workspace-aware command execution via the
`docker-builder-run` trampoline pattern. Both `x` and
`docker-builder-run` are published as release assets by
[docker-builder][docker-builder-releases]; see [README.md](./README.md#installation)
for the install snippet.

### Workspace Detection Algorithm

The script searches for `run.sh`:

1. **Repo Tool Workspaces**: Searches for `.repo` directory via
   brute-force parent directory traversal
2. **Git Workspace**: If no `.repo` found, tries `git rev-parse
   --show-superproject-working-tree` for submodules, falling back to `git
   rev-parse --show-toplevel` for regular repositories
3. **Brute Force**: If no VCS found, searches parent directories for
   executable `run.sh`

Once a workspace root is found, checks for executable `run.sh` at that
location. If not found, searches parent directories iteratively.

### Trampoline Pattern

When `run.sh` is found, `x` executes the trampoline sequence:

```text
x command args
    ↓
run.sh command args
    ├── /.dockerenv exists → exec command args (passthrough)
    └── host → docker-builder-run command args
                    ↓
               docker run ... entrypoint.sh
                    ↓
               command args (in container at CURDIR)
```

On the host, `run.sh` locates `docker-builder-run` and trampolines
into the container. Inside the container (`/.dockerenv` present),
`run.sh` passes through directly, so `x` works in both
environments without obstruction.

### Entrypoint Behaviour

The container entrypoint (from docker-builder base image) ensures
consistent behaviour across both DevContainer and CLI modes:

- **User Matching**: Creates container user with host UID/GID
- **Environment Setup**: Sets `WS`, `CURDIR`, and `PATH`
- **Directory Navigation**: Changes to `CURDIR` before execution
- **Command Execution**: Runs command as container user

See [docker-builder documentation][docker-builder-agent] for entrypoint
implementation details.

### Script Portability

Scripts must never include `x` in their commands. This ensures:

- **DevContainer**: `./script.sh` runs directly
- **Host**: `x ./script.sh` trampolines to container
- **Portability**: Same script works in both environments

## Verification and Debugging

### Mount Verification

To verify mounts are working correctly inside the container:

```bash
# Check for bind mounts
mount | grep bind | grep -E "(claude|docker-run-cache)"

# Or use findmnt
findmnt -t bind | grep -E "(${USER}|claude)"
```

Expected output should show bind mounts, not ext4 filesystem mounts.

### Environment Verification

To verify environment setup:

```bash
# Check environment variables
echo $WS
echo $CURDIR
echo $PATH

# Verify CURDIR navigation works
x pwd  # Should match current directory, not /
```

### Common Issues

1. **Mount not appearing**: Rebuild container after configuration
   changes
2. **Permission errors**: Ensure directories exist before container
   creation
3. **JSONC parsing**: The `json_sanitize` function handles VS Code's
   format

## Development Workflow

### First Time Setup

1. Clone the repository
2. `initializeCommand` in devcontainer.json runs init.js automatically
3. VS Code will build and start the DevContainer

## Code Quality Standards

### Markdown Files

- All markdown files must be tested against markdownlint
- Lists under numbered items require blank lines:
  - Add blank line before starting a bullet list under a numbered item
  - Add blank line after the numbered item before the sub-list
- Use consistent indentation for nested lists:
  - Sub-items under bullets: indent 2 spaces
  - Third-level items: indent 4 spaces
- Code blocks within lists should be indented to align with list text
- Lines should be shorter than 78 characters where practical
- Files must end with a single newline
- Fix any markdownlint violations before committing
- Test with `pnpx markdownlint-cli <filename>`

#### Markdown List Format Example

```markdown
1. **First level numbered item**

- Bullet list needs blank line before it
- Another bullet at same level

2. **Second numbered item**

- Sub-list with blank line separation
  - Nested item (2 space indent)
  - Another nested item
```

### VS Code Diagnostics

- Review VS Code diagnostics for all modified files
- Address any warnings or errors reported by the IDE
- Use the `mcp__ide__getDiagnostics` tool to check for issues

### EditorConfig Rules

Key rules from `.editorconfig`:

- **All files**: UTF-8, LF line endings, final newline, trim trailing spaces
- **Markdown**: 2-space indentation, preserve trailing spaces
- **JSON/YAML**: 2-space indentation
- **Shell scripts**: Tab indentation (size 8)

When working with docker-builder:

- **docker-builder changes**: Affect all environments using its base images
- **dev-env changes**: Only affect this specific DevContainer environment
- **Coordination needed**: Major changes to `docker-builder-run` or
  base images may require updates here

For docker-builder implementation details, see the
[docker-builder AGENT documentation][docker-builder-agent].

[docker-builder-agent]: https://github.com/amery/docker-builder/blob/master/AGENTS.md
[docker-builder-releases]: https://github.com/amery/docker-builder/releases/latest
