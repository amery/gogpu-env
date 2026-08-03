# syntax=docker/dockerfile:1
FROM quay.io/amery/docker-apptly-builder:latest

# Vulkan userspace for the webgpu (gogpu/wgpu) backend.
# mesa-vulkan-drivers ships lavapipe (lvp) — a conformant CPU
# implementation that returns correct results with no GPU — plus the
# Intel anv ICD for the Arc render node when one is passed in.
# vulkan-tools provides vulkaninfo for diagnostics.
#
# Compute only: this container has no display, so nothing here serves
# presentation.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      mesa-vulkan-drivers \
      vulkan-tools \
 && rm -rf /var/lib/apt/lists/*

# Bake the host-Ollama profile snippet in inline (not COPY/bind-mount) so it
# behaves identically under docker-builder-run and the generated devcontainer
# build. Quoted heredoc tag keeps $vars literal — they expand at login.
RUN cat > /etc/profile.d/ollama.sh <<'SH'
# Point CLI clients at the host's Ollama daemon, reachable inside the
# container as host.docker.internal, not localhost. POSIX sh, no `set -e`
# (runs in the caller's login shell).
if test -z "${OLLAMA_HOST:-}" && getent hosts host.docker.internal >/dev/null; then
	export OLLAMA_HOST=host.docker.internal:11434
fi

# srclight has no Ollama-host override, so it rides Ollama's OpenAI-compat
# API. Derive the base URL from OLLAMA_HOST (no trailing /v1 — the provider
# appends /v1/embeddings). Skip if a real OpenAI endpoint was set earlier.
if [ -z "${OPENAI_BASE_URL:-}" -a -n "${OLLAMA_HOST:-}" ]; then
	export OPENAI_BASE_URL="http://$OLLAMA_HOST"
	export OPENAI_API_KEY=ollama
	export SRCLIGHT_EMBED_REQUEST_TIMEOUT="${SRCLIGHT_EMBED_REQUEST_TIMEOUT:-120}"
fi
SH

# Enrol the workspace user in the GPU render node's group so the webgpu
# (Vulkan) backend can open a render device passed in via --device. The
# plugin serves both execution modes, at the moment each one has a root
# phase: the entrypoint sources it at container start for CLI
# (docker-builder-run), while the device is live, then drops to the user
# via `su -`, which inherits the new group; the generated devcontainer
# build runs it as a build step, where no device is attached and the
# gids arrive in GPU_RENDER_GIDS instead (see gen_dockerfile in
# .devcontainer/init.sh). Inlined (not COPY) to match the profile.d
# pattern. entrypoint.d plugin stdout is folded into the login profile,
# so this must emit nothing there.
RUN cat > /etc/entrypoint.d/15-gpu-render.sh <<'SH'
# A /dev/dri render node passed in via --device is owned by a host gid
# with no matching container group: the user cannot open the node, and
# a gid that resolves to no name upsets everything that reports one.
# Create or reuse a *named* group with that gid and enrol the workspace
# user, so both the `su -` login and a devcontainer's baked credentials
# carry it.
#
# The gid list has two sources, one per moment. At container start the
# render nodes are attached, so it is read from /dev/dri. At devcontainer
# image build time none is, so the host's gids are passed in through
# GPU_RENDER_GIDS. No-op when neither yields one. Keep stdout empty —
# gen_profile captures it.
_gids="${GPU_RENDER_GIDS:-}"
if [ -z "$_gids" ]; then
	for _dev in /dev/dri/renderD*; do
		# the glob stays literal when no render node is present — the
		# only expected miss, and the plugin's no-op exit
		[ -c "$_dev" ] || continue

		_gids="${_gids:+$_gids }$(stat -c %g "$_dev")"
	done
fi

# past here a failure is a real broken state: let set -e abort loudly
# rather than ship a user who silently cannot open the GPU
for _gid in $_gids; do
	_grp=$(getent group "$_gid" | cut -d: -f1)
	if [ -z "$_grp" ]; then
		_grp=render
		if getent group "$_grp" > /dev/null; then
			# a second node with a different gid cannot take the name
			_grp="render$_gid"
		fi

		groupadd -g "$_gid" "$_grp"
	fi

	usermod -aG "$_grp" "$USER_NAME"
done
unset _dev _gid _gids _grp
SH
