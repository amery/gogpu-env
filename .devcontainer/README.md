# Dev Container Configuration

This directory contains the development container configuration for
cross-platform support (Linux/macOS and Windows).

## Overview

The devcontainer setup supports both Unix-based systems (Linux/macOS)
and Windows through platform-specific initialisation scripts.

## Files

- `devcontainer.json` - Main configuration (user customisations preserved
  during updates)
- `Dockerfile` - Container image definition
- `init.js` - Cross-platform initialisation launcher
- `init.sh` - Unix/Linux/macOS initialisation script with OS detection
- `init.ps1` - Windows PowerShell initialisation script

## How It Works

1. When you open the project in VS Code with the Dev Containers extension,
   it runs `node .devcontainer/init.js`
2. The init.js script detects your operating system and runs the
   appropriate initialisation:
   - On Windows: Executes `init.ps1` using PowerShell
   - On Unix/Linux/macOS: Executes `init.sh`
3. The initialisation script:
   - Pulls the base image if it is not present locally, then reads its
     metadata
   - Generates a customised Dockerfile based on your user settings
   - Merges platform-specific mount paths into devcontainer.json
     (preserving user customisations)
   - Sets up required directories and files for the container

## Linux-Specific Requirements

### Linux Prerequisites

- Docker Engine or Docker Desktop for Linux
- Node.js (for the cross-platform launcher)
- jq (JSON processor) - Install with: `sudo apt-get install jq`
  (Debian/Ubuntu) or equivalent
- Standard Unix tools: sed, diff, grep
- VS Code with the Dev Containers extension

### Linux Path Handling

The Linux initialisation script (`init.sh`) handles:

- Standard POSIX paths
- HOME environment variable
- Unix file permissions and symbolic links

### Known Considerations on Linux

- Ensure your user has Docker permissions (add to docker group)
- SELinux may require additional container permissions
- Some distributions may need additional firewall configuration for Docker

## macOS-Specific Requirements

### macOS Prerequisites

- Docker Desktop for Mac
- Node.js (install via Homebrew: `brew install node`)
- jq (install via Homebrew: `brew install jq`)
- VS Code with the Dev Containers extension

### macOS Path Handling

The initialisation script (`init.sh`) automatically handles:

- macOS-specific Docker socket locations
- Homebrew dependency management
- Standard POSIX paths (same as Linux)

### Known Considerations on macOS

- Docker Desktop must be running before initialisation
- Homebrew is required for installing dependencies
- The script will prompt for installation of missing tools (like jq)
- Apple Silicon Macs may need Rosetta 2 for x86 containers

## Windows-Specific Requirements

### Windows Prerequisites

- Docker Desktop with the WSL 2 backend
- A standalone Node.js on your `PATH` (the runtime bundled inside VS
  Code is not exposed as a `node` command)
- Git for Windows on your `PATH` (GitHub Desktop's bundled git is not
  enough)
- PowerShell (included with Windows)
- VS Code with the Dev Containers extension

### Windows Path Handling

The Windows initialisation script (`init.ps1`) automatically handles:

- Converting Windows paths to Docker-compatible formats
- Using `USERPROFILE` instead of `HOME` environment variable
- Creating proper mount points for Windows file systems

### Known Limitations on Windows

- File permissions may differ from Unix systems
- Symbolic links require elevated permissions
- Line ending differences (CRLF vs LF) may need attention

## Troubleshooting

### Windows Issues

1. **PowerShell Execution Policy Error**
   - The init.js script runs PowerShell with `-ExecutionPolicy Bypass`
   - If you still encounter issues, run:
     `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

2. **Path Not Found Errors**
   - Ensure Docker Desktop is running
   - Check that the workspace path doesn't contain special characters
   - Verify mount paths in Docker Desktop settings

3. **Node.js Not Found**
   - Install Node.js from [nodejs.org](https://nodejs.org/)
   - Ensure it's added to your system PATH

### General Issues

1. **Manual Initialisation**
   - Unix/Linux/macOS: `./.devcontainer/init.sh`
   - Windows:
     `powershell -ExecutionPolicy Bypass -File .\.devcontainer\init.ps1`

## Customisation

### User Customisations (Persistent)

Edit `devcontainer.json` directly to add:

- VS Code extensions
- Container features
- Environment variables
- Forward ports
- Post-create commands
- Any other VS Code devcontainer settings

These changes will be preserved when the initialisation scripts run.

### Platform-Specific Customisations

To modify platform-specific behaviour:

1. Edit the appropriate initialisation script (`init.sh` or `init.ps1`)
2. The scripts only update platform-specific sections (mounts, paths)
3. User customisations in devcontainer.json are always preserved through
   merging

## Development

When making changes to the devcontainer setup:

1. Test on both Windows and Unix platforms
2. Ensure the generated Dockerfile works on both platforms
3. Update this documentation as needed
