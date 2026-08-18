# pi-container — AGENTS.md

## What this is

A wrapper that builds and runs the **pi coding agent** inside an **Apple container**
with a network sandbox. The agent can reach only a local inference server — not the open internet (unless the user supplies a flag).

## Key files

| File | Purpose |
|---|---|
| `Containerfile` | Image definition (JDK 21 + Node 22 + pi + dev tools). Built with `container build` |
| `scripts/run.sh` | Main entry point. Handles networking, mounts, Gradle warmup, and launches pi |
| `scripts/build.sh` | Builds the container image (run once on the host Mac) |
| `scripts/entrypoint.sh` | Container entrypoint — runs `pi`, then drops to a shell on exit |
| `scripts/gradle-warmup.sh` | Pre-downloads Gradle deps on the default network |
| `pi-config/` | Config mounted into the container as `/home/pi/.pi/agent` (settings, models, subagent definitions) |
| `pi-config/models.json.template` | Template rendered at launch with the egress proxy IP |
| `pi-config/agents/` | pi-subagent definitions (`*.md`) mounted as the container's user agents dir |

## How it works

1. `build.sh` builds the image tagged `pi-coding-agent:local`
2. `run.sh` sets up three container networks:
   - **sandboxed** — internal, no internet. Agent runs here.
   - **default** — full internet. Used for Gradle warmup.
   - **egress-proxy** — a `socat` container dual-homed on both, forwarding only to the inference server
3. The project directory is bind-mounted at `/projects/<name>`
4. `pi-config/` is rendered (proxy IP substituted) and mounted at `/home/pi/.pi/agent`
5. Pi runs inside the container; on exit, a bash shell remains for debugging

The **pi-subagent** extension is baked into the image at `/opt/pi-packages/pi-subagent`
(see the Containerfile) and enabled by the `packages` entry in `pi-config/settings.json`.
It adds a `subagent` tool; agent definitions live in `pi-config/agents/*.md` and are
mounted as the container's user agents dir. Baking under `~/.pi/agent` would not work —
the `pi-config/` bind mount hides everything the image places there.

## Running

```bash
# Build (once, on the host Mac)
./scripts/build.sh

# Run the agent on a project
PROJECT_DIR=~/my-project ./scripts/run.sh --model llama-local/current

# Drop into a shell for testing
./scripts/run.sh --shell

# Run with full internet access
./scripts/run.sh --with-internet

# Run without display access (display is on by default)
./scripts/run.sh --no-display --model llama-local/current
```

## Apple container docs

The `container` CLI source and documentation are at:
**https://github.com/apple/container**

Clone that repo if you need to deep-dive into the container runtime and aren't
operating on a Mac.

## Security Notes

This is a PUBLIC repository. Don't add secrets or API keys, be appropriately cautious.
