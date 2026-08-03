#!/bin/sh

# local is not in POSIX sh but is supported by the target shells (dash,
# bash); it is used by gen_gpu_opts below.
# shellcheck disable=SC3043
set -eu

# gen_gpu_opts
# Shape gpu.sh's render-node inventory into one flat `docker run` option
# string for CLI mode. The per-driver rationale lives in gpu.sh; what is
# specific here is the shape. The node's gid is not needed on this path:
# the 15-gpu-render.sh entrypoint plugin reads it off the live device as
# root and enrols the user before the drop to it. Emits nothing when no
# GPU is exposed.
gen_gpu_opts() {
	local dev drv nvidia_gpu='' opts=''

	while read -r dev drv _; do
		# the inventory is empty on a GPU-less host, leaving a single
		# blank line to skip
		[ -n "$dev" ] || continue

		case "$drv" in
		nvidia)
			nvidia_gpu=1
			;;
		*)
			opts="${opts:+$opts }--device $dev"
			;;
		esac
	done <<-EOT
	$(gpu_each_render_node)
	EOT

	# An NVIDIA proprietary GPU is reachable only through the NVIDIA
	# Container Toolkit; without nvidia-ctk the render node is dead and
	# --gpus is rejected, so drop the GPU. NVIDIA_DRIVER_CAPABILITIES=all
	# adds the `graphics` cap the Vulkan backend needs — the toolkit
	# otherwise exposes only compute+utility.
	gpu_has_nvidia_ctk || nvidia_gpu=''
	[ -z "$nvidia_gpu" ] || opts="${opts:+$opts }--gpus all -e NVIDIA_DRIVER_CAPABILITIES=all"

	[ -z "$opts" ] || printf '%s\n' "$opts"
}

# run.sh relies on docker-builder-run behaviour introduced in v1.23;
# refuse to trampoline through an older release that lacks it. The
# minimum is stored pre-encoded: 102300 is ver_to_num's rendering of
# 1.23 (major*100000 + minor*100 + patch).
RUN_MIN_VERSION=102300

# ver_to_num <major.minor.patch>
# Fold a dotted version into one comparable integer,
# major*100000 + minor*100 + patch, so "1.23" and "1.23.0" both become
# 102300. A missing minor or patch counts as 0; minor spans 0-999 and
# patch 0-99 before they would carry into the next field.
ver_to_num() {
	oldifs=$IFS
	IFS=.
	# split the dotted version into the positional parameters
	# shellcheck disable=SC2086
	set -- $1
	IFS=$oldifs
	echo $(( ${1:-0} * 100000 + ${2:-0} * 100 + ${3:-0} ))
}

# require_run_version <docker-builder-run> <min-decimal>
# Succeed when the resolved docker-builder-run is at least <min-decimal>
# (a ver_to_num-encoded minimum). Its -V banner prints
# "docker-builder-run <version>" on stderr before exiting non-zero, so
# merge stderr and read the version off that first line.
require_run_version() {
	ver=$("$1" -V 2>&1 | sed -n 's/^docker-builder-run //p')

	if [ -z "$ver" ]; then
		echo "docker-builder-run: cannot determine version" >&2
		return 1
	fi

	if [ "$(ver_to_num "$ver")" -lt "$2" ]; then
		echo "docker-builder-run $ver is too old, need >= 1.23" >&2
		return 1
	fi
}

if [ -f /.dockerenv ]; then
	: # inside container, pass-through silently
elif ! command -v docker > /dev/null 2>&1; then
	echo "docker: command not found" >&2
elif ! DOCKER_BUILDER_RUN=$(command -v docker-builder-run); then
	echo "docker-builder-run: command not found" >&2
elif ! require_run_version "$DOCKER_BUILDER_RUN" "$RUN_MIN_VERSION"; then
	: # require_run_version reported the reason on stderr
else
	set -- "$DOCKER_BUILDER_RUN" "$@"

	ME="$(readlink -f "$0")"
	export DOCKER_DIR="${ME%/*}"
	export DOCKER_RUN_WS="${DOCKER_DIR%/*}"

	# host GPU discovery, shared with .devcontainer/init.sh; only the
	# host path needs it, so it is sourced here rather than at the top
	# shellcheck source-path=SCRIPTDIR
	# shellcheck source=gpu.sh
	. "$DOCKER_DIR/gpu.sh"

	# bind-mount Claude configuration. docker-builder-run reads a bare
	# name off DOCKER_RUN_VOLUMES as a variable to resolve, so pass the
	# directory as CLAUDE_CONFIG_DIR; a leading ! marks .claude.json as a
	# literal file path, mounted as a file with its sandbox mount point
	# pre-created (needs docker-builder-run 1.23).
	export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	mkdir -p "$CLAUDE_CONFIG_DIR"
	[ -s "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"

	export DOCKER_RUN_VOLUMES="${DOCKER_RUN_VOLUMES:+$DOCKER_RUN_VOLUMES }CLAUDE_CONFIG_DIR !$HOME/.claude.json"

	# forward GPG agent socket for commit signing
	GPG_SOCK_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gnupg"
	if [ -d "$GPG_SOCK_DIR" ]; then
		# docker-builder-run evaluates DOCKER_EXTRA_OPTS as a command
		# line, so the embedded quotes are deliberate: they survive to
		# keep a path with spaces one argument.
		# shellcheck disable=SC2089
		export DOCKER_EXTRA_OPTS="${DOCKER_EXTRA_OPTS:+$DOCKER_EXTRA_OPTS }-v '$GPG_SOCK_DIR:$GPG_SOCK_DIR'"
	fi

	# expose host as host.docker.internal — Docker resolves the
	# host-gateway sentinel to the bridge gateway IP at container
	# start, replacing the brittle pattern of hard-coding 172.17.0.1.
	# shellcheck disable=SC2090
	export DOCKER_EXTRA_OPTS="${DOCKER_EXTRA_OPTS:+$DOCKER_EXTRA_OPTS }--add-host=host.docker.internal:host-gateway"

	# expose the host GPUs for the Vulkan (webgpu) backend (see
	# gen_gpu_opts). Guarded so a GPU-less host adds nothing.
	GPU_OPTS=$(gen_gpu_opts)
	if [ -n "$GPU_OPTS" ]; then
		export DOCKER_EXTRA_OPTS="${DOCKER_EXTRA_OPTS:+$DOCKER_EXTRA_OPTS }$GPU_OPTS"
	fi
fi

[ $# -gt 0 ] || set -- "${SHELL:-/bin/sh}"
exec "$@"
