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

if [ -f /.dockerenv ]; then
	: # inside container, pass-through silently
elif ! command -v docker > /dev/null 2>&1; then
	echo "docker: command not found" >&2
elif ! DOCKER_BUILDER_RUN=$(command -v docker-builder-run); then
	echo "docker-builder-run: command not found" >&2
else
	set -- "$DOCKER_BUILDER_RUN" "$@"

	ME="$(readlink -f "$0")"
	export DOCKER_DIR="${ME%/*}"
	export DOCKER_RUN_WS="${DOCKER_DIR%/*}"

	# bind-mount Claude configuration
	export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	mkdir -p "$CLAUDE_CONFIG_DIR"
	[ -s "$HOME/.claude.json" ] || echo '{}' > "$HOME/.claude.json"

	export DOCKER_RUN_VOLUMES="${DOCKER_RUN_VOLUMES:+$DOCKER_RUN_VOLUMES }CLAUDE_CONFIG_DIR"
	export DOCKER_EXTRA_OPTS="${DOCKER_EXTRA_OPTS:+$DOCKER_EXTRA_OPTS }-v '$HOME/.claude.json:$HOME/.claude.json'"

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
