# shellcheck shell=sh
#
# local is not in POSIX sh but is supported by the target shells (dash,
# bash); it is used throughout this file.
# shellcheck disable=SC3043
#
# Host GPU discovery, shared by the two launch paths: docker/run.sh
# (CLI, through docker-builder-run) and .devcontainer/init.sh
# (DevContainer, through generated runArgs). Sourced, never executed —
# each caller shapes the output its own way.
#
# The policy both callers apply: expose the host GPUs to the Vulkan
# (webgpu) backend, each by the mechanism its driver needs. The
# discriminator is the kernel driver bound to the render node, not the
# "open vs proprietary" label:
#
#   nouveau / i915 / xe / amdgpu / …  — any Mesa driver
#       Pass the /dev/dri render node: the in-image Mesa Vulkan stack
#       (anv, radv, NVK) drives it. The user still needs the node's
#       group to open it — granted by the 15-gpu-render.sh entrypoint
#       plugin, at container start in CLI mode and at image build time
#       in DevContainer mode.
#
#   nvidia  — proprietary *or* NVIDIA's open kernel modules
#       Skip the render node: it yields no Vulkan device, since the
#       access path is the NVIDIA userspace ICD (via /dev/nvidia*), not
#       the DRM node, and Mesa NVK only binds nouveau. Reach the GPU
#       through the NVIDIA Container Toolkit instead (--gpus), which is
#       only usable when nvidia-ctk is installed.

# gpu_each_render_node
# Emit one line per usable render node, "<dev> <driver> <gid>": the
# device path, the kernel driver bound to it (read from sysfs), and the
# node's group. Emits nothing on a GPU-less host, and nothing on macOS,
# where /dev/dri does not exist: the glob stays literal and the single
# candidate fails the device test.
gpu_each_render_node() {
	local dev drv

	for dev in /dev/dri/renderD*; do
		[ -c "$dev" ] || continue

		drv=$(readlink -f "/sys/class/drm/${dev##*/}/device/driver" 2> /dev/null || true)
		printf '%s %s %s\n' "$dev" "${drv##*/}" "$(stat -c %g "$dev")"
	done
}

# gpu_has_nvidia_ctk
# True when the NVIDIA Container Toolkit is installed. Without it the
# proprietary driver's render node is dead and --gpus is rejected, so a
# caller that finds an nvidia node must drop the GPU rather than request
# it.
gpu_has_nvidia_ctk() {
	command -v nvidia-ctk > /dev/null 2>&1
}
