#!/bin/sh

set -eu

# gen_gpu_opts — emit the `docker run` options that expose the host GPUs
# to the Vulkan (webgpu) backend, each by the mechanism its driver needs.
# The discriminator is the kernel driver bound to the render node (read
# from sysfs), not the "open vs proprietary" label:
#
#   nouveau / i915 / xe / amdgpu / …  — any Mesa driver
#       Pass the /dev/dri render node: the in-image Mesa Vulkan stack
#       (anv, radv, NVK) drives it. The 15-gpu-render.sh entrypoint plugin
#       enrols the user in the node's group so it is openable.
#
#   nvidia  — proprietary *or* NVIDIA's open kernel modules
#       Skip the render node: it yields no Vulkan device, since the access
#       path is the NVIDIA userspace ICD (via /dev/nvidia*), not the DRM
#       node, and Mesa NVK only binds nouveau. Reach the GPU through the
#       NVIDIA Container Toolkit instead (--gpus), requested only when
#       nvidia-ctk is installed.
#
# Emits nothing on a GPU-less host: the glob stays literal and every
# candidate fails the device test.
gen_gpu_opts() {
	local dev drv nvidia_gpu= opts=

	for dev in /dev/dri/renderD*; do
		[ -c "$dev" ] || continue

		drv=$(readlink -f "/sys/class/drm/${dev##*/}/device/driver" 2> /dev/null || true)
		case "${drv##*/}" in
		nvidia)
			nvidia_gpu=1
			;;
		*)
			opts="${opts:+$opts }--device $dev"
			;;
		esac
	done

	# An NVIDIA proprietary GPU is reachable only through the NVIDIA
	# Container Toolkit; without nvidia-ctk the render node is dead and
	# --gpus is rejected, so drop the GPU. NVIDIA_DRIVER_CAPABILITIES=all
	# adds the `graphics` cap the Vulkan backend needs — the toolkit
	# otherwise exposes only compute+utility.
	command -v nvidia-ctk > /dev/null 2>&1 || nvidia_gpu=
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
		export DOCKER_EXTRA_OPTS="${DOCKER_EXTRA_OPTS:+$DOCKER_EXTRA_OPTS }-v '$GPG_SOCK_DIR:$GPG_SOCK_DIR'"
	fi

	# expose host as host.docker.internal — Docker resolves the
	# host-gateway sentinel to the bridge gateway IP at container
	# start, replacing the brittle pattern of hard-coding 172.17.0.1.
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
