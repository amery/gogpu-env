#!/bin/sh

# local is not in POSIX sh but is supported by the target shells (dash,
# bash); it is used throughout this script.
# shellcheck disable=SC3043
set -eu

err() {
	if [ $# -eq 0 ]; then
		cat
	else
		echo "$*"
	fi | sed -e 's|^|E:|g' >&2
}

die() {
	err "$@"
	exit 1
}

# Detect OS type
detect_os() {
	case "$(uname -s)" in
		Linux*)  echo "linux" ;;
		Darwin*) echo "macos" ;;
		*)       echo "unknown" ;;
	esac
}

OS_TYPE=$(detect_os)

# Platform-specific checks
case "$OS_TYPE" in
	macos)
		# Check for Homebrew on macOS
		if ! command -v brew >/dev/null 2>&1; then
			die <<-EOT
			Homebrew is required on macOS. Install from https://brew.sh
			Run: /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
			EOT
		fi

		# Check for jq, offer to install if missing
		if ! command -v jq >/dev/null 2>&1; then
			die <<-EOT
			jq is required but not installed.
			Install with: brew install jq
			EOT
		fi

		# Docker socket location on macOS
		DOCKER_SOCKET="/var/run/docker.sock"
		if [ ! -S "$DOCKER_SOCKET" ]; then
			DOCKER_SOCKET="$HOME/.docker/run/docker.sock"
			if [ ! -S "$DOCKER_SOCKET" ]; then
				die <<-EOT
				Docker socket not found. Ensure Docker Desktop is running.
				Checked locations:
				  - /var/run/docker.sock
				  - $HOME/.docker/run/docker.sock
				EOT
			fi
		fi
		;;

	linux)
		# Check for jq on Linux
		if ! command -v jq >/dev/null 2>&1; then
			die <<-EOT
			jq is required but not installed.
			Install with:
			  Debian/Ubuntu: sudo apt-get install jq
			  RHEL/CentOS: sudo yum install jq
			  Arch: sudo pacman -S jq
			EOT
		fi

		# Check Docker permissions
		if ! docker info >/dev/null 2>&1; then
			die <<-EOT
			Cannot connect to Docker daemon. Ensure Docker is running and you have permissions.
			You may need to add your user to the docker group:
			  sudo usermod -aG docker $USER
			Then log out and back in.
			EOT
		fi
		;;

	*)
		die "Unsupported operating system: $(uname -s)"
		;;
esac

cd "$(dirname "$0")/.."

B=".devcontainer"
C=".docker-run-cache"

[ -n "${USER:-}" ] || USER=$(id -un)
[ -d "${HOME:-}" ] || die "no HOME"

# Renames a file only if the target file does not exist or differs from the source file.
#
# Args:
#   $1 - Temporary file path (source)
#   $2 - Target file path
#
# Behavior:
#   - If the target file is empty or different from the source, moves the source file to the target
#   - If the target file is identical, removes the source file
#   - Useful for atomic file updates with minimal changes
rename() {
	local T="$1" F="$2"

	if ! test -s "$F" || ! diff -u "$F" "$T" >&2; then
		mv "$T" "$F"
	else
		rm -f "$T"
	fi
}

# Dockerfile
#
DOCKERFILE=docker/Dockerfile

get_base_image() {
	sed -n -e 's|^[\t ]*FROM[\t ]\+\([^\t ]\+\)[\t ]*$|\1|p' "$1" | tail -n1
}

# docker inspect only sees local images; pull on first run so the base
# image's metadata label is readable instead of silently lost.
may_pull_image() {
	local from="$1"

	${DOCKER:-docker} image inspect "$from" >/dev/null 2>&1 ||
		${DOCKER:-docker} pull "$from" >&2
}

get_metadata() {
	local from="$1"

	${DOCKER:-docker} inspect --format='{{index .Config.Labels "devcontainer.metadata"}}' "$from" || echo '[]'
}

metadata() {
	local from="$1"

	get_metadata "$from" | jq -c '. + [{"containerUser": $USER}]' --arg USER "$USER"
}

gen_dockerfile() {
	local from="$1"

	cat <<EOT
$(cat "$DOCKERFILE")

# bypassed entrypoint
#
RUN /devcontainer-init.sh "$USER" "$HOME" && rm -f /devcontainer-init.sh

# run as user
#
LABEL devcontainer.metadata='$(metadata "$from")'

USER ${USER}
EOT
}

FROM=$(get_base_image "$DOCKERFILE")
may_pull_image "$FROM" || die "could not pull $FROM"

F="$B/Dockerfile"
T="$F.$$"
# expand $T now: the temp path is fixed at trap setup and removed verbatim
# shellcheck disable=SC2064
trap "rm -f '$T'" EXIT
gen_dockerfile "$FROM" > "$T"
rename "$T" "$F"

# devcontainer.json
#
# WS_ENV/HOME_ENV are devcontainer.json substitution tokens, written into the
# JSON literally; VS Code expands them at container creation, not the shell.
# Single-quoted so the shell leaves them untouched.
# shellcheck disable=SC2016
readonly WS_ENV='${localWorkspaceFolder}'
# shellcheck disable=SC2016
readonly HOME_ENV='${localEnv:HOME}'

gen_json_overlay() {
	# GPG agent socket forwarding
	local gpg_mount=""
	local gpg_sock_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gnupg"
	if [ -d "$gpg_sock_dir" ]; then
		gpg_mount=', {
		"source": "'"$gpg_sock_dir"'",
		"target": "'"$gpg_sock_dir"'",
		"type": "bind"
	}'
	fi

	cat <<EOT
{
	"containerEnv": {
		"GOPATH": "$WS_ENV",
		"WS": "$WS_ENV",
		"CURDIR": "$WS_ENV"
	},
	"workspaceMount": "source=$WS_ENV,target=$WS_ENV,type=bind,consistency=cached",
	"workspaceFolder": "$WS_ENV",
	"mounts": [{
		"source": "$WS_ENV/$C/$HOME_ENV",
		"target": "$HOME_ENV",
		"type": "bind"
	}, {
		"source": "$HOME_ENV/.claude",
		"target": "$HOME_ENV/.claude",
		"type": "bind"
	}, {
		"source": "$HOME_ENV/.claude.json",
		"target": "$HOME_ENV/.claude.json",
		"type": "bind"
	}$gpg_mount]
}
EOT
}


# Strip // line comments (JSONC) and validate. A // inside a string value (e.g.
# an https:// URL) is preserved: awk walks each line tracking whether it is
# inside a string and only cuts a // that begins outside one. JSON strings never
# span lines, so per-line scanning suffices. Only // line comments are
# handled; /* */ block comments are not.
json_sanitize() {
	awk '
	{
		out = ""
		in_str = 0
		i = 1
		while (i <= length($0)) {
			c = substr($0, i, 1)
			if (in_str) {
				out = out c
				if (c == "\\") {
					i++
					out = out substr($0, i, 1)
				} else if (c == "\"") {
					in_str = 0
				}
			} else if (c == "\"") {
				in_str = 1
				out = out c
			} else if (c == "/" && substr($0, i + 1, 1) == "/") {
				break
			} else {
				out = out c
			}
			i++
		}
		print out
	}
	' "$1" | jq -e .
}

json_merge() {
	jq -e -s '.[0] * .[1]' "$@" --indent 2
}

# devcontainer.json must exist in version control
F="$B/devcontainer.json"
[ -s "$F" ] || die "devcontainer.json not found or empty."

T0="$F.0.$$"
T1="$F.1.$$"
T2="$F.2.$$"
# expand the temp paths now: fixed at trap setup and removed verbatim
# shellcheck disable=SC2064
trap "rm -f '$T0' '$T1' '$T2'" EXIT

json_sanitize "$F" > "$T0"
gen_json_overlay > "$T1"
json_merge "$T0" "$T1" > "$T2"
rename "$T2" "$F"
rm -f "$T0" "$T1"

#
# mount points
#

# Bound directories (sandboxed)
# pre-quoted path list; single iteration intended, extend by adding lines
# shellcheck disable=SC2066
for x in \
	"$HOME" \
	; do
	mkdir -p "$C$x"
done

# Host-bound directories
for x in \
	"$PWD" \
	"$HOME/.claude" \
	; do
	mkdir -p "$C$x" "$x"
done

# Host-bound files
# pre-quoted path list; single iteration intended, extend by adding lines
# shellcheck disable=SC2066
for x in \
	"$HOME/.claude.json" \
	; do
	touch "$C$x"
	case "$x" in
	*.json)
		[ -s "$x" ] || echo '{}' > "$x"
		;;
	*)
		touch "$x"
		;;
	esac
done

echo "Devcontainer initialization completed successfully"
