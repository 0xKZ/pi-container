#!/usr/bin/env bash
# Starts pi in an Apple container, network-sandboxed so it can only reach
# our local inference server -- not the open internet.
#
# Expects two mounts:
#   - pi-config/    -> /home/pi/.pi/agent  (provider config, AGENTS.md, extensions)
#   - $PROJECT_DIR  -> /workspace          (the project to work on)
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# --------------------------------------------------------------------------
# Network sandbox overview
#
# Goal: the agent container must NOT be able to reach the open internet, but
# DOES need to reach our local inference server, which lives on the Mac
# host's "default" container network at 192.168.64.1:8080.
#
# We tried doing this with a host-side pf (packet filter) firewall rule
# first, blocking egress on the bridge interface apple `container` uses.
# That doesn't work reliably -- pf does not consistently filter vmnet-bridged
# traffic on recent macOS, so traffic slipped through unblocked.
#
# Instead we lean on `container`'s own network isolation, which doesn't rely
# on a filter that could be bypassed -- it works by simply never creating a
# route to the internet in the first place:
#
#   - "sandboxed" is a `container network create --internal` network. Internal
#     networks have no gateway out to the internet or the host's other
#     networks, by construction. The agent runs ONLY on this network.
#
#   - "default" is the network `container` creates automatically. It's where
#     our llama-server / inference host service is reachable, at the host's
#     vmnet gateway address (currently 192.168.64.1).
#
#   - "egress-proxy" is a tiny container running `socat`, dual-homed onto
#     BOTH "sandboxed" and "default". It listens on its "sandboxed"-side IP
#     and forwards everything to 192.168.64.1:8080 on the "default" side.
#     This is the ONLY bridge between the two networks, and it only forwards
#     to one specific host:port -- so the agent can reach the inference
#     server, but nothing else "default" can see, and nothing on the internet.
#
# Because the proxy's IP on the "sandboxed" network is assigned dynamically
# each time it starts, we can't hardcode it anywhere persistent (like
# models.json checked into git). Instead, models.json is a *template* with a
# placeholder, and we render the real IP into a generated copy at launch
# time (see render_config below).
#
# The egress-proxy container is deliberately NOT torn down when this script
# exits. We run multiple agent sessions in parallel (e.g. one per project),
# and they all share the same proxy -- tearing it down when any one session
# ends would break the others still running. ensure_egress_proxy() below
# just checks if it's already up and reuses it; only starts a fresh one if
# it's missing or stopped.
# --------------------------------------------------------------------------

INFERENCE_SERVER_HOST_IP="192.168.64.1"
INFERENCE_SERVER_HOST_PORT="8080"

# --shell drops into an interactive shell instead of launching pi, with the
# same network + mounts the agent itself would get. Must be the first arg.
SHELL_MODE=false
if [ "${1:-}" = "--shell" ]; then
  SHELL_MODE=true
  shift
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "PROJECT_DIR='$PROJECT_DIR' does not exist." >&2
  exit 1
fi

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
get_sandboxed_ip() {
  container inspect "$1" | jq -r '.[0].status.networks[] | select(.network == "sandboxed") | .ipv4Address' | cut -d/ -f1
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

ensure_sandboxed_network
ensure_egress_proxy "$INFERENCE_SERVER_HOST_IP" "$INFERENCE_SERVER_HOST_PORT"
EGRESS_PROXY_IP="$(get_sandboxed_ip egress-proxy)"

if [ -z "$EGRESS_PROXY_IP" ]; then
  echo "Failed to determine egress-proxy sandboxed-network IP." >&2
  exit 1
fi

# Render the agent config now -- both branches below (shell and normal) use
# it, so the --shell environment matches the real agent run as closely as
# possible (same mounts, same rendered models.json, same network).
RENDERED_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-config.XXXXXX")"
render_config "$EGRESS_PROXY_IP" "$INFERENCE_SERVER_HOST_PORT" "$RENDERED_CONFIG_DIR"

if [ "$SHELL_MODE" = true ]; then
  echo "Shell mode: sandboxed network, proxy reachable at ${EGRESS_PROXY_IP}:${INFERENCE_SERVER_HOST_PORT}" >&2
  container run --rm -it \
    --network sandboxed \
    --entrypoint sh \
    --volume "$RENDERED_CONFIG_DIR:/home/pi/.pi/agent" \
    --volume "$PROJECT_DIR:/workspace" \
    --workdir /workspace \
    --env "EGRESS_PROXY_IP=$EGRESS_PROXY_IP" \
    --env "PROJECT_NAME=$PROJECT_NAME" \
    "$IMAGE_TAG" \
    -c "export PS1='(AGENT-SANDBOX-${PROJECT_NAME}) \w \$ '; exec bash --norc"

  exit 0
fi

container run \
  --network sandboxed \
  --rm \
  --interactive \
  --tty \
  --volume "$RENDERED_CONFIG_DIR:/home/pi/.pi/agent" \
  --volume "$PROJECT_DIR:/workspace" \
  --workdir /workspace \
  --env "PROJECT_NAME=$PROJECT_NAME" \
  "$IMAGE_TAG" \
  "$@"
