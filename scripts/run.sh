#!/usr/bin/env bash
# Starts pi in an Apple container, network-sandboxed so it can only reach
# our local inference server -- not the open internet.
#
# Expects two mounts:
#   - pi-config/    -> /home/pi/.pi/agent  (provider config, AGENTS.md, extensions)
#   - $PROJECT_DIR  -> /projects/<name>    (the project to work on, name = basename of PROJECT_DIR)
# Additional folders can be mounted with --add-folder <path> -> /extra/<name>
#
# Example:
#   PROJECT_DIR=~/projects/small-test-repo ./scripts/run.sh --model llama-local/Qwen3.6-27B
#   PROJECT_DIR=~/projects/my-project ./scripts/run.sh --add-folder ../other-repo --model llama-local/Qwen3.6-27B
#   PROJECT_DIR=~/projects/game ./scripts/run.sh --with-display --model llama-local/Qwen3.6-27B
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

# Gradle isolation: we must NOT let the container write Gradle metadata
# into the project tree that the host also sees. Gradle writes to TWO
# locations that both store absolute paths:
#
#   1. GRADLE_USER_HOME (~/.gradle/) -- dependency cache, daemon state
#   2. <project>/.gradle/             -- build output cleanup, task artifacts,
#                                       Spotless file hashes, etc.
#
# Because the project directory is bind-mounted, location #2 is shared
# between the container (/projects/...) and the host (/Users/...).
# If the container writes paths like /projects/<project>/... into the
# project's .gradle/, the host's Gradle reads them and fails with
# "target files must be within project dir" errors.
#
# Solution: both locations use container-dedicated directories on the
# host at $CONTAINER_GRADLE_CACHE/<project-name>. These directories are:
#   - Outside the project tree, so the host's Gradle never finds them
#   - Bind-mounted into the container, so Gradle inside uses them exclusively
#   - Shared between the warmup and agent containers for the same project,
#     so dependency downloads and build cache are reused
CONTAINER_GRADLE_CACHE="${HOME}/.pi-container-gradle"
CONTAINER_GRADLE_CACHE_PROJECT="${CONTAINER_GRADLE_CACHE}/${PROJECT_NAME}"

# Container-dedicated replacement for the project's own .gradle/ directory.
# Mounted over <project>/.gradle/ so the container never writes into the
# host-visible project tree. Lives under the per-project cache so parallel
# containers on the same project still share it.
CONTAINER_PROJECT_GRADLE_DIR="${CONTAINER_GRADLE_CACHE_PROJECT}/project-gradle"

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

# Inference server host IP (Apple vmnet gateway). Override via env var if
# your setup uses a different address.
INFERENCE_SERVER_HOST_IP="${INFERENCE_SERVER_HOST_IP:-192.168.64.1}"
INFERENCE_SERVER_HOST_PORT="${INFERENCE_SERVER_HOST_PORT:-8080}"

# --shell drops into an interactive shell instead of launching pi, with the
# same network + mounts the agent itself would get.
# --with-internet uses the "default" network (full internet access) instead
# of the "sandboxed" network, and skips the Gradle warmup step.
# --with-display enables access to a display for graphics operations. If
# XQuartz is installed on the host (X11 socket at /tmp/.X11-unix exists),
# the host display is mounted into the container. Otherwise, a virtual
# framebuffer (Xvfb) is started inside the container for headless rendering.
# --add-folder <path> mounts an additional folder (relative or absolute) at
# /extra/<folder-name> inside the container, so the agent can read files from
# other projects or locations. Can be repeated for multiple folders.
# These flags can appear in any position among the arguments.
SHELL_MODE=false
WITH_INTERNET=false
WITH_DISPLAY=false
ADD_FOLDERS=()
REMAINING_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) SHELL_MODE=true; shift ;;
    --with-internet) WITH_INTERNET=true; shift ;;
    --with-display) WITH_DISPLAY=true; shift ;;
    --add-folder)
      if [ $# -lt 2 ]; then
        echo "--add-folder requires a path argument." >&2
        exit 1
      fi
      ADD_FOLDERS+=("$2"); shift 2 ;;
    *) REMAINING_ARGS+=("$1"); shift ;;
  esac
done
# Guard against empty array expansion under set -u.
# In strict bash, "${REMAINING_ARGS[@]}" on an empty array throws
# "unbound variable". The ${arr[@]+"${arr[@]}"} pattern expands to nothing
# when the array is empty, and to the full array otherwise.
if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
  set -- "${REMAINING_ARGS[@]}"
fi

# Resolve --add-folder paths to absolute paths and validate they exist.
# Each folder is mounted at /extra/<basename> inside the container.
EXTRA_FOLDER_MOUNTS=()  # pairs of "host_path:/extra/folder_name"
for folder in "${ADD_FOLDERS[@]+"${ADD_FOLDERS[@]}"}"; do
  # Resolve to absolute path (creates no files, just canonicalises)
  local_abs=""
  if [[ "$folder" == /* ]]; then
    local_abs="$folder"
  else
    local_abs="$(cd "$(dirname "$folder")" && pwd)/$(basename "$folder")"
  fi
  if [ ! -d "$local_abs" ]; then
    echo "--add-folder path '$folder' resolved to '$local_abs' which is not a directory." >&2
    exit 1
  fi
  EXTRA_FOLDER_MOUNTS+=("$local_abs:/extra/$(basename "$local_abs")")
done

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

  # Pinned to a digest for reproducibility.
  #   To find the digest of a new image:
  #     container image inspect <image>:<tag> | jq -r '.[].configuration.descriptor.digest'
  container run -d --name egress-proxy \
    --network sandboxed \
    --network default \
    alpine/socat@sha256:7f9a06753033f2b7de18edc2353f2c15153413d95a039163c6db270fc7a6c3b0 \
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
# If with_internet is "false", appends a no-internet notice to APPEND_SYSTEM.md.
# If extra mounts are provided (args 5+), appends a path mapping table so the
# agent can resolve host paths the user references to their /extra/... locations.
render_config() {
  local proxy_ip="$1" proxy_port="$2" out_dir="$3" with_internet="$4"
  shift 4
  mkdir -p "$out_dir"
  cp -R "$REPO_ROOT/pi-config/." "$out_dir/"
  sed -e "s/__EGRESS_PROXY_IP__/${proxy_ip}/g" \
      -e "s/__EGRESS_PROXY_PORT__/${proxy_port}/g" \
      "$REPO_ROOT/pi-config/models.json.template" > "$out_dir/models.json"
  if [ "$with_internet" != true ]; then
    printf '\n> **No internet access is available.** Do not attempt to make
> network requests, fetch URLs, or install packages from remote registries.\n' \
      >> "$out_dir/APPEND_SYSTEM.md"
  fi
  # Append path mapping for --add-folder mounts so the agent knows where
  # to find files when the user references a host path that doesn't exist
  # inside the container.
  if [ $# -gt 0 ]; then
    {
      printf '\n## Extra Folder Mounts\n\n'
      printf 'The following folders from your machine are mounted inside this container\n'
      printf 'under `/extra/`. If a path you reference does not exist, check this mapping:\n\n'
      printf '| Your path | Container path |\n'
      printf '|---|---|\n'
      for mount in "$@"; do
        local host_path="${mount%%:*}"
        local container_path="${mount#*:}"
        printf '| `%s` | `%s` |\n' "$host_path" "$container_path"
      done
    } >> "$out_dir/APPEND_SYSTEM.md"
  fi
}

# Pre-downloads Gradle dependencies if the project has a Gradle wrapper.
# Runs on the "default" network (real internet access) so the wrapper
# distribution and dependencies can be downloaded. The sandboxed agent run
# later reuses the same container-dedicated Gradle cache via bind mount.
# Directory setup is done earlier (unconditionally) so this only handles
# the actual warmup build run.
warm_gradle_if_needed() {
  if [ ! -f "$PROJECT_DIR/gradlew" ]; then
    return 0
  fi

  echo "Gradle project detected. Warming cache at $CONTAINER_GRADLE_CACHE_PROJECT..." >&2

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
  # We bind-mount the container-dedicated Gradle cache as GRADLE_USER_HOME
  # so that Gradle uses it instead of the default ~/.gradle/. This cache
  # lives outside the project tree, so the host's Gradle never reads it.
  #
  # We also mount a container-dedicated directory over the project's own
  # .gradle/ folder. Gradle writes task artifacts, build output cleanup
  # metadata, and Spotless file hashes there -- all with absolute paths.
  # Without this mount, the container would write /projects/... paths into
  # the host-visible project tree, causing path conflicts on the host.
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
    --volume "$CONTAINER_GRADLE_CACHE_PROJECT:/home/pi/.gradle" \
    --volume "$CONTAINER_PROJECT_GRADLE_DIR:/projects/$PROJECT_NAME/.gradle" \
    --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
    --volume "$warmup_script:/tmp/gradle-warmup.sh:ro" \
    --workdir "/projects/$PROJECT_NAME" \
    --env "GRADLE_USER_HOME=/home/pi/.gradle" \
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

# Wait for the egress-proxy socat listener to be ready.
# Apple's container runtime does not support --health-cmd, so we test
# connectivity directly by running socat inside the proxy container.
wait_for_egress_proxy() {
  local retries=15
  for ((i = 1; i <= retries; i++)); do
    if container exec egress-proxy socat -t1 TCP:localhost:8080 /dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "WARNING: egress-proxy did not become healthy within ${retries}s." >&2
  echo "The agent may experience initial connection failures." >&2
}

ensure_container_service
ensure_sandboxed_network

# When --with-internet is set, the agent runs on the default network with
# full internet access. No proxy is needed — connect directly to the
# inference server. This also saves the memory cost of the socat container.
if [ "$WITH_INTERNET" = true ]; then
  EGRESS_PROXY_IP="$INFERENCE_SERVER_HOST_IP"
else
  ensure_egress_proxy "$INFERENCE_SERVER_HOST_IP" "$INFERENCE_SERVER_HOST_PORT"
  wait_for_egress_proxy
  EGRESS_PROXY_IP="$(get_proxy_ip egress-proxy sandboxed)"

  if [ -z "$EGRESS_PROXY_IP" ]; then
    echo "Failed to determine egress-proxy sandboxed-network IP." >&2
    exit 1
  fi
fi

# Render the agent config now -- both branches below (shell and normal) use
# it, so the --shell environment matches the real agent run as closely as
# possible (same mounts, same rendered models.json, same network).
RENDERED_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-config.XXXXXX")"
trap 'rm -rf "$RENDERED_CONFIG_DIR"' EXIT

# When --with-internet is set, point models.json at the inference server
# directly (it's reachable on the default network) instead of routing
# through the proxy unnecessarily.
if [ "$WITH_INTERNET" = true ]; then
  MODEL_PROXY_IP="$INFERENCE_SERVER_HOST_IP"
else
  MODEL_PROXY_IP="$EGRESS_PROXY_IP"
fi
render_config "$MODEL_PROXY_IP" "$INFERENCE_SERVER_HOST_PORT" "$RENDERED_CONFIG_DIR" "$WITH_INTERNET" \
  "${EXTRA_FOLDER_MOUNTS[@]+"${EXTRA_FOLDER_MOUNTS[@]}"}"

# If the project has a Gradle wrapper, set up the container-dedicated Gradle
# directories. This runs regardless of --with-internet so that the project's
# .gradle/ is always isolated (preventing path pollution with the host).
if [ -f "$PROJECT_DIR/gradlew" ]; then
  mkdir -p "$CONTAINER_GRADLE_CACHE_PROJECT"
  mkdir -p "$CONTAINER_PROJECT_GRADLE_DIR"

  # Apply daemon idle timeout so the JVM doesn't sit around eating memory
  # in the container after the warmup (or agent) finishes. 3600000 ms = 1 hour.
  cat > "$CONTAINER_GRADLE_CACHE_PROJECT/gradle.properties" <<'EOF'
org.gradle.daemon.idletimeout=3600000
EOF
fi

# Pre-download Gradle dependencies on the default network (real internet).
# Skipped when --with-internet since the agent container already has internet.
if [ "$WITH_INTERNET" != true ]; then
  warm_gradle_if_needed
fi

# Build the Gradle cache volume args if the container-dedicated cache exists.
# This is only created when the project has a gradlew.
GRADLE_VOLUME_ARGS=()
if [ -d "$CONTAINER_GRADLE_CACHE_PROJECT" ]; then
  GRADLE_VOLUME_ARGS=(
    --volume "$CONTAINER_GRADLE_CACHE_PROJECT:/home/pi/.gradle"
    --volume "$CONTAINER_PROJECT_GRADLE_DIR:/projects/$PROJECT_NAME/.gradle"
  )
fi

# Build volume args for --add-folder mounts.
EXTRA_VOLUME_ARGS=()
for mount in "${EXTRA_FOLDER_MOUNTS[@]+"${EXTRA_FOLDER_MOUNTS[@]}"}"; do
  EXTRA_VOLUME_ARGS+=(--volume "$mount")
done

# Display access: --with-display enables graphics operations inside the container.
# Two modes are supported:
#   1. X11 (host XQuartz): If /tmp/.X11-unix exists on the host, mount it into
#      the container so apps render on the Mac's actual display.
#   2. Xvfb (virtual framebuffer): If no host X11 is available, start Xvfb inside
#      the container for headless rendering. Games/test code can create windows
#      and render to the virtual display.
DISPLAY_MODE="none"   # "none" | "x11" | "xvfb"
DISPLAY_VOLUME_ARGS=()
DISPLAY_ENV_ARGS=()
if [ "$WITH_DISPLAY" = true ]; then
  if [ -d "/tmp/.X11-unix" ]; then
    DISPLAY_MODE="x11"
    DISPLAY_VOLUME_ARGS=(--volume "/tmp/.X11-unix:/tmp/.X11-unix:ro")
    DISPLAY_ENV_ARGS=(--env "DISPLAY=:0" --env "DISPLAY_MODE=x11")
    echo "Display mode: X11 (host XQuartz at /tmp/.X11-unix)" >&2
  else
    DISPLAY_MODE="xvfb"
    DISPLAY_ENV_ARGS=(--env "DISPLAY=:99" --env "DISPLAY_MODE=xvfb")
    echo "Display mode: Xvfb (virtual framebuffer at :99)." >&2
    echo "  (Install XQuartz on the Mac for real display access.)" >&2
  fi
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
    ${GRADLE_VOLUME_ARGS[@]+"${GRADLE_VOLUME_ARGS[@]}"} \
    ${EXTRA_VOLUME_ARGS[@]+"${EXTRA_VOLUME_ARGS[@]}"} \
    ${DISPLAY_VOLUME_ARGS[@]+"${DISPLAY_VOLUME_ARGS[@]}"} \
    --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
    --workdir "/projects/$PROJECT_NAME" \
    --env "EGRESS_PROXY_IP=$EGRESS_PROXY_IP" \
    --env "PROJECT_NAME=$PROJECT_NAME" \
    --env "GRADLE_USER_HOME=/home/pi/.gradle" \
    ${DISPLAY_ENV_ARGS[@]+"${DISPLAY_ENV_ARGS[@]}"} \
    "$IMAGE_TAG" \
    -c '
      if [ "${DISPLAY_MODE}" = "xvfb" ]; then
        Xvfb "${DISPLAY:-:99}" -screen 0 1920x1080x24 &
        for i in 1 2 3 4 5; do
          if xdpyinfo >/dev/null 2>&1; then break; fi
          sleep 0.2
        done
      fi
      export PS1="(AGENT-SANDBOX-${PROJECT_NAME}) \w \$ "
      exec bash --norc
    '

  exit 0
fi

# Unique session ID so parallel runs on the same project don't collide.
# The name "pi-<project>-<short-id>" is still readable in `container list`.
SESSION_ID="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

container run \
  --name "pi-${PROJECT_NAME}-${SESSION_ID}" \
  --network "$([ "$WITH_INTERNET" = true ] && echo default || echo sandboxed)" \
  --rm \
  --interactive \
  --tty \
  --memory "$MEMORY" \
  --volume "$RENDERED_CONFIG_DIR:/home/pi/.pi/agent" \
  ${GRADLE_VOLUME_ARGS[@]+"${GRADLE_VOLUME_ARGS[@]}"} \
  ${EXTRA_VOLUME_ARGS[@]+"${EXTRA_VOLUME_ARGS[@]}"} \
  ${DISPLAY_VOLUME_ARGS[@]+"${DISPLAY_VOLUME_ARGS[@]}"} \
  --volume "$PROJECT_DIR:/projects/$PROJECT_NAME" \
  --workdir "/projects/$PROJECT_NAME" \
  --env "PROJECT_NAME=$PROJECT_NAME" \
  --env "GRADLE_USER_HOME=/home/pi/.gradle" \
  ${DISPLAY_ENV_ARGS[@]+"${DISPLAY_ENV_ARGS[@]}"} \
  "$IMAGE_TAG" \
  "$@"
