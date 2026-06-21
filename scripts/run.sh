#!/usr/bin/env bash
# Starts pi in an Apple container, network-sandboxed so it can only reach
# our local inference server -- not the open internet.
#
# Expects two mounts:
#   - pi-config/    -> /home/pi/.pi/agent  (provider config, AGENTS.md, extensions)
#   - $PROJECT_DIR  -> /projects/<name>    (the project to work on, name = basename of PROJECT_DIR)
#
# Example:
#   PROJECT_DIR=~/projects/small-test-repo ./scripts/run.sh --model llama-local/Qwen3.6-27B
#
# (where '--model' is an argument forwarded to pi, and an entry in the models.json)
#
# Use --shell to drop into an interactive shell instead of running pi, with
# the exact same network and mounts the agent would get. Handy for poking at
# the sandbox (curl-ing the proxy, checking DNS, etc.) without doing the
# network setup by hand every time.
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-pi-coding-agent:local}"
MEMORY="${MEMORY:-4g}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# Each project's Gradle cache lives at its own .gradle/ directory inside
# the project -- the same directory Gradle creates when run locally.
# We bind-mount this directly into the container so that:
#
#   - A repo already built locally starts with a warm cache (the warmup
#     step below is often a fast no-op).
#   - Each project gets its own isolated cache, so parallel agent runs
#     across different repos don't interfere with each other.
#   - The cache is just more project state alongside the /workspace mount.
GRADLE_CACHE_DIR="$PROJECT_DIR/.gradle"

# Path to the Gradle warmup script. Defaults to the bundled script at
# scripts/gradle-warmup.sh (copied into the image at /usr/local/bin/gradle-warmup.sh).
# Set this to any script (absolute or relative to cwd) to customize the warmup.
# The script is bind-mounted into the container and run from /workspace.
GRADLE_WARMUP_SCRIPT="${GRADLE_WARMUP_SCRIPT:-$REPO_ROOT/scripts/gradle-warmup.sh}"

# --------------------------------------------------------------------------
# Network sandbox
#
# The agent container must NOT reach the open internet, but DOES need to
# reach our local inference server on the Mac host at 192.168.64.1:8080.
# We achieve this using three `container` networks and a small proxy:
#
#   - "sandboxed" -- an internal network (no gateway to the internet or
#     host). The agent container runs ONLY on this network.
#
#   - "default" -- the network `container` creates automatically. The
#     inference server is reachable here at the host's vmnet gateway.
#     The Gradle warmup run also uses this network since it needs real
#     internet access to download dependencies.
#
#   - "egress-proxy" -- a small `socat` container dual-homed onto BOTH
#     "sandboxed" and "default". It listens on its sandboxed-side IP and
#     forwards everything to 192.168.64.1:8080 on the default side. This
#     is the only bridge between the two networks, so the agent can reach
#     the inference server but nothing else.
#
# The proxy's sandboxed IP is assigned dynamically, so models.json is a
# template with placeholders that we render at launch time
# (see render_config below).
#
# The egress-proxy container is shared across parallel agent sessions and
# is NOT torn down when this script exits. ensure_egress_proxy() checks
# if it's already running and reuses it.
# --------------------------------------------------------------------------

INFERENCE_SERVER_HOST_IP="192.168.64.1"
INFERENCE_SERVER_HOST_PORT="8080"

# --shell drops into an interactive shell instead of launching pi, with the
# same network + mounts the agent itself would get.
# --with-internet uses the "default" network (full internet access) instead
# of the "sandboxed" network, and skips the Gradle warmup step.
# These flags can appear in any position among the arguments.
SHELL_MODE=false
WITH_INTERNET=false
REMAINING_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) SHELL_MODE=true; shift ;;
    --with-internet) WITH_INTERNET=true; shift ;;
    *) REMAINING_ARGS+=("$1"); shift ;;
  esac
done
set -- "${REMAINING_ARGS[@]}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "PROJECT_DIR='$PROJECT_DIR' does not exist." >&2
  exit 1
fi

# Ensures the container daemon (container-apiserver) is running.
# `container system status` sends a health check to the API server;
# it exits non-zero when the service is not up. If so, we start it.
ensure_container_service() {
  if container system status >/dev/null 2>&1; then
    return 0
  fi

  echo "Container service is not running. Starting..." >&2
  container system start
}

# Creates the internal (no-internet-route) network if it doesn't already
# exist. Safe to call every run -- no-ops once the network is there.
ensure_sandboxed_network() {
  # NOTE: the network's name lives at .configuration.name in the JSON output,
  # not a top-level .name -- mirrors how `container inspect` nests container
  # state under .configuration / .status rather than flat top-level fields.
  if ! container network list --format json | jq -e '.[] | select(.configuration.name == "sandboxed")' >/dev/null 2>&1; then
    container network create sandboxed --internal --subnet 192.168.200.0/24
  fi
}

# Starts the dual-homed socat forwarder if one isn't already running.
# Reused across script invocations on purpose -- see the network sandbox
# overview comment above for why we don't tear this down on exit.
ensure_egress_proxy() {
  local target_ip="$1" target_port="$2"

  if container list --format json | jq -e '.[] | select(.configuration.id == "egress-proxy" and .status.state == "running")' >/dev/null 2>&1; then
    return 0
  fi

  # Remove a stopped/stale container under this name before recreating it
  # (e.g. left over from a crash). `|| true` because this errors harmlessly
  # if no such container exists at all.
  container rm -f egress-proxy >/dev/null 2>&1 || true

  container run -d --name egress-proxy \
    --network sandboxed \
    --network default \
    alpine/socat \
    TCP-LISTEN:8080,fork,reuseaddr "TCP:${target_ip}:${target_port}"
}

# Reads back the proxy's address on the "sandboxed" side specifically (it
# has a different address on each of its two networks -- we want the one
# the agent container can actually route to).
get_proxy_ip() {
  local container_name="$1" network="$2"
  container inspect "$container_name" | jq -r ".[0].status.networks[] | select(.network == \"${network}\") | .ipv4Address" | cut -d/ -f1
}

# Builds the config dir we'll mount as /home/pi/.pi/agent. Copies everything
# from pi-config/ as-is, then renders models.json from models.json.template,
# substituting in today's egress-proxy IP/port. We render into a fresh temp
# dir per run (rather than editing pi-config/models.json in place) so that:
#   (a) parallel sessions never stomp on each other's rendered config, and
#   (b) the checked-in template never gets overwritten with a stale IP.
render_config() {
  local proxy_ip="$1" proxy_port="$2" out_dir="$3"
  mkdir -p "$out_dir"
  cp -R "$REPO_ROOT/pi-config/." "$out_dir/"
  sed -e "s/__EGRESS_PROXY_IP__/${proxy_ip}/g" \
      -e "s/__EGRESS_PROXY_PORT__/${proxy_port}/g" \
      "$REPO_ROOT/pi-config/models.json.template" > "$out_dir/models.json"
}

# Pre-populates this project's .gradle cache if it has a Gradle wrapper.
# Runs on the "default" network (real internet access) so the wrapper
# distribution and dependencies can be downloaded. The sandboxed agent run
# later reuses that same now-warm .gradle/ via a bind mount.
warm_gradle_if_needed() {
  if [ ! -f "$PROJECT_DIR/gradlew" ]; then
    return 0
  fi

  IS_GRADLE_PROJECT=true
  mkdir -p "$GRADLE_CACHE_DIR"

  echo "Gradle project detected. Warming cache at $GRADLE_CACHE_DIR (fast if already warm)..." >&2

  # Resolve the warmup script to an absolute path.
  local warmup_script="$GRADLE_WARMUP_SCRIPT"
  if [[ "$warmup_script" != /* ]]; then
    warmup_script="$(cd "$(dirname "$warmup_script")" && pwd)/$(basename "$warmup_script")"
  fi

  if [ ! -f "$warmup_script" ]; then
    echo "WARNING: Gradle warmup script not found at $warmup_script" >&2
    echo "Skipping Gradle warmup." >&2
    return 0
  fi

  # --entrypoint bash: overrides the image's default ENTRYPOINT so our
  # script runs directly instead of being passed to `pi`.
  #
  # --cpus / --memory: bumped up from the image default (4 CPU / 1GiB) --
  # 1GiB is tight for a JVM build and can cause silent stalls.
  #
  # We bind-mount the warmup script into the container at /tmp/gradle-warmup.sh
  # so that custom scripts (outside the image) are available at runtime.
  #
  # We do NOT exit 1 on failure: a build failure from the project's own
  # compile errors is not a reason to block the agent. A dependency
  # download failure would be, but since we can't cleanly distinguish
  # those from the exit code alone, we warn and launch the agent anyway.
  if ! container run --rm \
    --network default \
    --entrypoint bash \
    --cpus 4 \
    --memory 4g \
    --volume "$GRADLE_CACHE_DIR:/home/pi/.gradle" \
    --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
    --volume "$warmup_script:/tmp/gradle-warmup.sh:ro" \
    --workdir "/projects/$PROJECT_NAME" \
    "$IMAGE_TAG" \
    -c "/tmp/gradle-warmup.sh"; then
    echo "Gradle warmup did not complete successfully -- this is OK if the" >&2
    echo "project currently has compile errors you're about to fix. If" >&2
    echo "dependencies genuinely failed to download (network/registry" >&2
    echo "issue), the agent may still hit missing-dependency errors once" >&2
    echo "sandboxed. See output above for details." >&2
  else
    echo "Gradle cache warmed." >&2
  fi
}

ensure_container_service
ensure_sandboxed_network
ensure_egress_proxy "$INFERENCE_SERVER_HOST_IP" "$INFERENCE_SERVER_HOST_PORT"
if [ "$WITH_INTERNET" = true ]; then
  EGRESS_PROXY_IP="$(get_proxy_ip egress-proxy default)"
else
  EGRESS_PROXY_IP="$(get_proxy_ip egress-proxy sandboxed)"
fi

if [ -z "$EGRESS_PROXY_IP" ]; then
  echo "Failed to determine egress-proxy sandboxed-network IP." >&2
  exit 1
fi

# Render the agent config now -- both branches below (shell and normal) use
# it, so the --shell environment matches the real agent run as closely as
# possible (same mounts, same rendered models.json, same network).
RENDERED_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-config.XXXXXX")"
render_config "$EGRESS_PROXY_IP" "$INFERENCE_SERVER_HOST_PORT" "$RENDERED_CONFIG_DIR"

# Whether $PROJECT_DIR actually has a Gradle wrapper -- set to true inside
# warm_gradle_if_needed if so. Defaults to false so that non-Gradle projects
# never try to mount a .gradle directory that was never created.
IS_GRADLE_PROJECT=false

if [ "$WITH_INTERNET" != true ]; then
  warm_gradle_if_needed
fi

# Only mount .gradle when this is actually a Gradle project -- otherwise
# GRADLE_CACHE_DIR was never created (warm_gradle_if_needed returned early
# without an mkdir), and passing --volume with a source path that doesn't
# exist makes `container run` fail outright rather than just skipping it.
GRADLE_VOLUME_ARGS=()
if [ "$IS_GRADLE_PROJECT" = true ]; then
  GRADLE_VOLUME_ARGS=(--volume "$GRADLE_CACHE_DIR:/home/pi/.gradle")
fi

if [ "$SHELL_MODE" = true ]; then
  local_network_label="sandboxed"
  if [ "$WITH_INTERNET" = true ]; then
    local_network_label="default (internet access)"
  fi
  echo "Shell mode: ${local_network_label} network, proxy reachable at ${EGRESS_PROXY_IP}:${INFERENCE_SERVER_HOST_PORT}" >&2
  container run --rm -it \
    --network "$([ "$WITH_INTERNET" = true ] && echo default || echo sandboxed)" \
    --entrypoint sh \
    --volume "$RENDERED_CONFIG_DIR:/home/pi/.pi/agent" \
    "${GRADLE_VOLUME_ARGS[@]}" \
    --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
    --workdir "/projects/$PROJECT_NAME" \
    --env "EGRESS_PROXY_IP=$EGRESS_PROXY_IP" \
    --env "PROJECT_NAME=$PROJECT_NAME" \
    "$IMAGE_TAG" \
    -c "export PS1='(AGENT-SANDBOX-${PROJECT_NAME}) \w \$ '; exec bash --norc"

  exit 0
fi

container run \
  --name "pi-${PROJECT_NAME}" \
  --network "$([ "$WITH_INTERNET" = true ] && echo default || echo sandboxed)" \
  --rm \
  --interactive \
  --tty \
  --memory "$MEMORY" \
  --volume "$RENDERED_CONFIG_DIR:/home/pi/.pi/agent" \
  "${GRADLE_VOLUME_ARGS[@]}" \
  --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
  --workdir "/projects/$PROJECT_NAME" \
  --env "PROJECT_NAME=$PROJECT_NAME" \
  "$IMAGE_TAG" \
  "$@"
