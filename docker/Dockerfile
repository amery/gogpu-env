FROM quay.io/amery/docker-apptly-builder:latest

# Vulkan userspace for the webgpu (gogpu/wgpu) backend.
# mesa-vulkan-drivers ships lavapipe (lvp) — a conformant CPU
# implementation that returns correct results with no GPU — plus the
# Intel anv ICD for the Arc render node when one is passed in.
# vulkan-tools provides vulkaninfo for diagnostics.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mesa-vulkan-drivers \
      vulkan-tools \
 && rm -rf /var/lib/apt/lists/*

# Enrol the workspace user in the GPU render node's group at container
# init so the webgpu (Vulkan) backend can open a render device passed
# in via --device. Inlined (not COPY) so it behaves identically under
# docker-builder-run and the generated devcontainer build, matching the
# profile.d pattern. entrypoint.d plugins are sourced as root after the
# user is created, before the drop to it; their stdout is folded into
# the login profile, so this must emit nothing there.
RUN cat > /etc/entrypoint.d/15-gpu-render.sh <<'SH'
# A /dev/dri render node passed in via --device is owned by a host gid
# with no matching container group, so the workspace user cannot open
# it. Create or reuse a group with that gid and enrol the user, so the
# later `su -` inherits the supplementary group. No-op when no device
# is present. Keep stdout empty — gen_profile captures it.
for _dev in /dev/dri/renderD*; do
	# the glob stays literal when no render node is present — the only
	# expected miss, and the plugin's no-op exit. Past here a failure is
	# a real broken state: let set -e abort init loudly rather than ship
	# a user who silently cannot open the GPU.
	[ -c "$_dev" ] || continue

	_gid=$(stat -c %g "$_dev")
	_grp=$(getent group "$_gid" | cut -d: -f1)
	if [ -z "$_grp" ]; then
		groupadd -g "$_gid" render
		_grp=render
	fi

	usermod -aG "$_grp" "$USER_NAME"
done
unset _dev _gid _grp
SH
