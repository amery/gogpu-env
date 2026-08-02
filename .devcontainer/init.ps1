# PowerShell initialization script for Windows devcontainer support
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "E: $Message" -ForegroundColor Red
}

function Stop-WithError {
    param([string]$Message)
    Write-ErrorMessage $Message
    exit 1
}

# Change to parent directory
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Split-Path -Parent $scriptPath)

$B = ".devcontainer"
$C = ".docker-run-cache"

# Get user and home information
if (-not $env:USERNAME) {
    Stop-WithError "no USERNAME environment variable"
}
# Sanitize username for Linux compatibility
# Replace spaces and invalid characters with underscores, convert to lowercase
$USER = $env:USERNAME -replace '[^a-zA-Z0-9._-]', '_' -replace '^[0-9]', '_$0' | ForEach-Object { $_.ToLower() }

if (-not $env:USERPROFILE) {
    Stop-WithError "no USERPROFILE"
}
# $HOME is an automatic variable; under Set-StrictMode shadowing it is a
# hazard. $UserHome is the real Windows home (e.g. C:\Users\amery); the
# container-side path is derived separately with ConvertTo-ContainerPath.
$UserHome = $env:USERPROFILE

# Function to rename file if different
function Rename-IfDifferent {
    param(
        [string]$TempFile,
        [string]$TargetFile
    )

    if (-not (Test-Path $TargetFile) -or (Get-Item $TargetFile).Length -eq 0) {
        Move-Item -Force $TempFile $TargetFile
    } elseif ((Get-FileHash $TempFile).Hash -ne (Get-FileHash $TargetFile).Hash) {
        Move-Item -Force $TempFile $TargetFile
    } else {
        Remove-Item $TempFile
    }
}

# Write $Content as UTF-8 without a BOM and with a single trailing newline,
# matching init.sh's heredoc, `jq` and `echo` output. Windows PowerShell 5.1's
# `Out-File -Encoding UTF8` prepends a BOM to every generated file — which can
# break Docker's parse of the Dockerfile's leading `# syntax=` / `FROM` line and
# corrupts the JSON — whereas .NET's UTF8Encoding($false) never does.
# Set-Location does not move .NET's working directory, so the path — relative or
# absolute — is resolved against the PowerShell location first.
function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($full, $Content + "`n", $utf8NoBom)
}

# Dockerfile generation
$DOCKERFILE = "docker/Dockerfile"

function Get-BaseImage {
    param([string]$FILE)

    Get-Content $FILE | Where-Object { $_ -match '^\s*FROM\s+(\S+)\s*$' } |
        ForEach-Object { $matches[1] } | Select-Object -Last 1
}

# docker inspect only sees local images; pull on first run so the base
# image's metadata label is readable instead of silently lost. Mirrors
# init.sh's may_pull_image.
function Initialize-Image {
    param([string]$FROM)

    # The top-level $ErrorActionPreference = "Stop" promotes a native command's
    # stderr into a terminating error under Windows PowerShell 5.1, so the
    # missing-image `docker image inspect` (and `docker pull`'s own progress on
    # stderr) would abort the script before its exit code could be read. Relax
    # the preference for these native calls and branch on the exit code, as the
    # shell's `image inspect >/dev/null 2>&1 || pull` does. The assignment is
    # function-local, so it reverts on return.
    $ErrorActionPreference = "Continue"

    & docker image inspect $FROM 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }

    & docker pull $FROM 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "could not pull $FROM"
    }
}

function Get-Metadata {
    param([string]$FROM)

    try {
        $metadata = & docker inspect --format='{{index .Config.Labels "devcontainer.metadata"}}' $FROM 2>$null
        if ($LASTEXITCODE -ne 0) { return '[]' }
        return $metadata
    } catch {
        return '[]'
    }
}

function Get-UpdatedMetadata {
    param([string]$FROM)

    $metadata = Get-Metadata $FROM
    # ConvertFrom-Json yields $null for `[]` and a bare object for a
    # single-entry array, and Windows PowerShell 5.1's ConvertTo-Json unwraps a
    # one-element array back to a bare object. Force array context, then
    # serialise each entry and assemble the array by hand so
    # devcontainer.metadata stays a JSON array regardless of entry count or
    # PowerShell version.
    $items = @($metadata | ConvertFrom-Json)
    $items += @{containerUser = $USER}
    $parts = $items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
    return "[$($parts -join ',')]"
}

# Function to translate Windows path to container path
function ConvertTo-ContainerPath {
    param([string]$WindowsPath)
    
    # Check if Docker is using WSL backend
    $dockerInfo = & docker version --format json 2>$null | ConvertFrom-Json
    $isWSL = $false
    
    if ($dockerInfo -and $dockerInfo.Server) {
        # Check for WSL in Docker context or OS info
        if ($dockerInfo.Server.Os -match 'linux' -and 
            ($env:WSL_DISTRO_NAME -or (& docker context ls 2>$null | Select-String 'wsl'))) {
            $isWSL = $true
        }
    }
    
    # Convert path based on Docker backend
    if ($isWSL) {
        # WSL format: /mnt/c/Users/...
        return $WindowsPath -replace '^([A-Z]):\\', '/mnt/$1/' -replace '\\', '/' | 
               ForEach-Object { $_.ToLower() }
    } else {
        # Docker Desktop format: /c/Users/...
        return $WindowsPath -replace '^([A-Z]):\\', '/$1/' -replace '\\', '/'
    }
}

# Generate Dockerfile content
function New-Dockerfile {
    param([string]$FROM)

    $baseContent = Get-Content $DOCKERFILE -Raw
    $metadata = Get-UpdatedMetadata $FROM
    # Translate Windows home path to container path
    $containerHome = ConvertTo-ContainerPath $env:USERPROFILE

    return @"
$baseContent

# bypassed entrypoint
#
RUN /devcontainer-init.sh "$USER" "$containerHome" && rm -f /devcontainer-init.sh

# run as user
#
LABEL devcontainer.metadata='$metadata'

USER $USER
"@
}

# Write Dockerfile
$FROM = Get-BaseImage $DOCKERFILE
Initialize-Image $FROM
$F = "$B/Dockerfile"
$T = "$F.tmp"
Write-TextFile $T (New-Dockerfile $FROM)
Rename-IfDifferent $T $F

# Generate JSON overlay
function New-JsonOverlay {
    # On Windows the ${localWorkspaceFolder} / ${localEnv:HOME} tokens that
    # init.sh emits resolve to host paths (C:\...) invalid inside the
    # container, so container-side paths are baked in concretely while mount
    # sources stay as tokens. The output therefore differs from the Linux one
    # in path values, by design.
    $containerHome = ConvertTo-ContainerPath $env:USERPROFILE
    $workspaceFolder = ConvertTo-ContainerPath $PWD.Path
    
    # [ordered] on every hashtable so ConvertTo-Json emits keys in init.sh's
    # fixed order (containerEnv, workspaceMount, workspaceFolder, mounts; each
    # mount source, target, type) — a plain @{} iterates in hash order and would
    # churn the merged file's key order run to run.
    $overlay = [ordered]@{
        containerEnv = [ordered]@{
            GOPATH = $workspaceFolder
            WS = $workspaceFolder
            CURDIR = $workspaceFolder
        }
        workspaceMount = 'source=${localWorkspaceFolder},target=' + $workspaceFolder + ',type=bind,consistency=cached'
        workspaceFolder = $workspaceFolder
        mounts = @(
            [ordered]@{
                # The sandboxed-home source cannot use the ${localEnv:USERPROFILE}
                # token: it resolves to C:\Users\... and would embed a drive
                # colon mid-path. Bake the translated container path instead.
                source = '${localWorkspaceFolder}/' + $C + $containerHome
                target = $containerHome
                type = 'bind'
            },
            [ordered]@{
                source = '${localEnv:USERPROFILE}/.claude'
                target = "$containerHome/.claude"
                type = 'bind'
            },
            [ordered]@{
                source = '${localEnv:USERPROFILE}/.claude.json'
                target = "$containerHome/.claude.json"
                type = 'bind'
            }
        )
    }
    return $overlay | ConvertTo-Json -Depth 10
}

# Strip // line comments (JSONC), mirroring init.sh's json_sanitize. The regex
# keeps whole strings ($1) so a // inside a value (https://) survives; JSON
# strings never span lines, so a per-line scan suffices. Only // line comments
# are handled — /* */ block comments are not.
function ConvertFrom-Jsonc {
    param([string]$Path)

    $stripped = Get-Content $Path |
        ForEach-Object { $_ -replace '("(?:[^"\\]|\\.)*")|//.*', '$1' }
    return ($stripped -join "`n" | ConvertFrom-Json)
}

# Recursive merge matching jq's `.[0] * .[1]` (init.sh's json_merge): objects
# merge by key; anything else takes the overlay (so arrays replace rather than
# concatenate).
function Merge-JsonValue {
    param($Base, $Overlay)

    if ($Base    -isnot [System.Management.Automation.PSCustomObject] -or
        $Overlay -isnot [System.Management.Automation.PSCustomObject]) {
        # comma stops the return enumerating a single-element array, which
        # would collapse mounts:[x] to mounts:x
        return ,$Overlay
    }

    # An ordinal (case-sensitive) comparer keeps keys differing only in case
    # distinct, as jq's `*` does; a plain [ordered]@{} is case-insensitive and
    # would fold them on insertion.
    $out = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)
    foreach ($p in $Base.PSObject.Properties) { $out[$p.Name] = $p.Value }
    foreach ($p in $Overlay.PSObject.Properties) {
        if ($out.Contains($p.Name)) {
            $out[$p.Name] = Merge-JsonValue $out[$p.Name] $p.Value
        } else {
            $out[$p.Name] = $p.Value
        }
    }
    # Return the dictionary raw: casting through [PSCustomObject] re-folds the
    # case-distinct keys the ordinal comparer just preserved. ConvertTo-Json
    # serialises the dictionary whole (dictionaries are not pipeline-enumerated,
    # so no comma guard is needed here).
    return $out
}

# Match init.sh's `jq --indent 2`: PowerShell 5.1's ConvertTo-Json uses
# four-space indents and sometimes a double-space colon, churning the tracked
# file on every run. The indent unit is detected, so PS7 (already two-space) is
# left alone.
function Format-Json {
    param([string]$Json)

    $lines = $Json -split "\r?\n"

    $unit = 0
    foreach ($l in $lines) {
        if ($l -match '^( +)\S') { $unit = $matches[1].Length; break }
    }

    $out = foreach ($l in $lines) {
        if ($unit -gt 0 -and $l -match '^( +)(.*)$') {
            $l = (' ' * ($matches[1].Length / $unit * 2)) + $matches[2]
        }
        $l -replace '^(\s*"(?:[^"\\]|\\.)*":)\s+', '$1 '
    }

    return ($out -join "`n")
}

function Merge-JsonFiles {
    param(
        [string]$BaseFile,
        [string]$OverlayContent
    )

    $base = ConvertFrom-Jsonc $BaseFile
    $overlay = $OverlayContent | ConvertFrom-Json

    $merged = Merge-JsonValue $base $overlay | ConvertTo-Json -Depth 10
    return (Format-Json $merged)
}

# Update devcontainer.json
$F = "$B/devcontainer.json"

# devcontainer.json must exist in version control, mirroring init.sh's
# `[ -s "$F" ] || die`.
if (-not (Test-Path $F) -or (Get-Item $F).Length -eq 0) {
    Stop-WithError "devcontainer.json not found or empty."
}

$T = "$F.tmp"
$overlayJson = New-JsonOverlay
$mergedJson = Merge-JsonFiles $F $overlayJson
Write-TextFile $T $mergedJson
Rename-IfDifferent $T $F

# Create mount points
#
# Cache-side mount points live under $C keyed by the *container* (translated,
# POSIX-style) path, so they match the overlay's resolved mount sources; real
# host directories and files are created at their Windows paths. On Linux the
# two coincide, on Windows they diverge, so each entry carries both.
$containerHome = ConvertTo-ContainerPath $env:USERPROFILE
$workspaceFolder = ConvertTo-ContainerPath $PWD.Path

# Bound directory (sandboxed home)
New-Item -ItemType Directory -Force -Path "$C$containerHome" | Out-Null

# Host-bound directories: the real host path plus its cache-side mount point
@(
    @{ Host = $PWD.Path;           Container = $workspaceFolder },
    @{ Host = "$UserHome/.claude"; Container = "$containerHome/.claude" }
) | ForEach-Object {
    New-Item -ItemType Directory -Force -Path "$C$($_.Container)" | Out-Null
    New-Item -ItemType Directory -Force -Path $_.Host | Out-Null
}

# Host-bound files
@(
    @{ Host = "$UserHome/.claude.json"; Container = "$containerHome/.claude.json" }
) | ForEach-Object {
    New-Item -ItemType File -Force -Path "$C$($_.Container)" | Out-Null

    if ($_.Host -match '\.json$') {
        if (-not (Test-Path $_.Host) -or (Get-Item $_.Host).Length -eq 0) {
            Write-TextFile $_.Host '{}'
        }
    } else {
        New-Item -ItemType File -Force -Path $_.Host | Out-Null
    }
}

Write-Host "Devcontainer initialization completed successfully"
