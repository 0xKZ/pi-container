
# What this is

A wrapper that runs the pi coding agent inside a network-sandboxed Apple container.

**Full Disclosure**: This project is mostly vibe-coded. It is not exactly a bastion of high engineering quality (I don't like maintaining bash scripts, but I am too lazy to rework this into something like Rust). You should fork this repo and customize things as you need. At this time I am not going through the effort to make this flexible enough to work for everyone. Maybe one day!

# Prerequisites

- **Apple Silicon Mac** with the [`container` CLI](https://github.com/apple/container) installed
- A **local inference server** running and listening on `192.168.64.1:8080` (or a port you override via `INFERENCE_SERVER_HOST_PORT`)

# Usage

## Build the container image (once, on the host):

`./scripts/build.sh`

The `Containerfile` defines what tools and runtimes are available inside the agent container. It is set up for my personal use case — edit it to add or remove packages, then rebuild with `./scripts/build.sh`.

## Models

`llama-local/current` is just a stable slot pointing at the local OpenAI-compatible server — whatever model it is currently serving. To add or change providers/models, edit `pi-config/models.json.template` (see the [pi models documentation](https://pi.dev/docs/latest/models) for the format).

## Running the agent

```
PROJECT_DIR=~/development/my_project_directory ./scripts/run.sh --model llama-local/current
```

### Running with internet access

Use `--with-internet` to launch the container on the `default` network with full internet access. This also skips the Gradle warmup step since the container can download dependencies on its own.

```
PROJECT_DIR=~/my-project ./scripts/run.sh --with-internet --model llama-local/current
```

### Running with OpenRouter

Use `--openrouter --with-internet` to use pi's built-in OpenRouter provider instead of your local inference server. This requires the `OPENROUTER_API_KEY` environment variable. When using this mode, `models.json` is not rendered — pi uses its full built-in OpenRouter model list, and the local `llama-local` provider is not visible.

```
PROJECT_DIR=~/my-project ./scripts/run.sh --openrouter --with-internet --model openrouter/deepseek/deepseek-v4-flash-0731
```

> **Note:** Set `OPENROUTER_API_KEY` before running. To avoid leaking your key in shell history, use one of:
>
> ```
> # Option A: export in your current shell (not written to history if added to ~/.profile)
> export OPENROUTER_API_KEY="sk-or-v1-YOUR_KEY_HERE"
> 
> # Option B: use a .env file (recommended)
> echo 'OPENROUTER_API_KEY=sk-or-v1-YOUR_KEY_HERE' > ~/.pi-container-env
> chmod 600 ~/.pi-container-env
> set -a; source ~/.pi-container-env; set +a
> # ⚠️ Avoid placing this file in directories synced by iCloud, Dropbox, etc.
> ```
> Then run `./scripts/run.sh` as shown above with the key already exported.

`--openrouter` requires `--with-internet` (OpenRouter is a cloud API) and will error if either `--with-internet` or `OPENROUTER_API_KEY` is missing. It also requires `--model` to specify which OpenRouter model to use (e.g. `--model openrouter/deepseek/deepseek-v4-flash-0731`). If you use the [fish convenience wrapper](#fish-shell-convenience-wrapper) with `PI_SANDBOX_DEFAULT_MODEL_OPENROUTER` set, the model is injected automatically and you don't need to pass `--model` manually.

`--openrouter` can be combined with `--shell` to drop into a debugging shell with internet access and the `OPENROUTER_API_KEY` environment variable available — useful for testing OpenRouter connectivity or debugging auth issues.

### Notes on llama-server

When hosting with llama-server, use `--host 0.0.0.0` — this exposes the server to your LAN but is required for the container to reach it.

### Convenience wrapper

For a `pi-agent` convenience command, see the [Fish shell convenience wrapper](#fish-shell-convenience-wrapper) in the Appendix. (Fish-only; skip if you use another shell.)

### Parallel sessions

You can run multiple agent sessions in parallel. Each gets a unique container name (`pi-<project>-<hex>`) and they share the same `egress-proxy`. The proxy is reused across runs and not torn down when a session ends.

### Stopping a session

Press `Ctrl+D` to exit pi. Press it again to exit the post-exit container shell and stop the container. Alternatively, stop the container from another terminal with `container stop pi-<project>-<hex>`.

## Verifying the network sandbox

Before trusting the agent with real work, confirm the sandbox blocks the open internet while still allowing access to the local inference server. Drop into a shell with `./scripts/run.sh --shell` and run:

```bash
curl --max-time 5 https://www.google.com/        # should fail
curl --max-time 5 http://192.168.64.1:8080       # should fail
curl http://$EGRESS_PROXY_IP:8080                # should succeed
```

If the first two succeed, the sandbox isn't isolating the container — investigate before running the agent on anything sensitive.

## Session Persistence

Pi sessions (conversation history) are stored in `.pi/sessions/` inside each project directory. This is configured via `sessionDir` in `pi-config/settings.json`. Because the project directory is bind-mounted into the container, sessions persist across container restarts and can be resumed with `pi -c` or `pi -r`.

Each project gets its own isolated session store. Add `.pi/` to your project's `.gitignore` if you don't want session data in version control.

## pi-config

The `pi-config/` directory is mounted into the container as the agent's config. Subdirectories like `extensions/` and `themes/` are passed through as-is. For details on all supported config files, see the [pi documentation](https://pi.dev/).

## Post-exit shell

When pi finishes its session, the container entrypoint drops you into a bash shell instead of exiting. This lets you inspect the workspace or debug issues. The container is still running until you type `exit`.

# Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PROJECT_DIR` | `$(pwd)` | Project directory to bind-mount into the container |
| `IMAGE_TAG` | `pi-coding-agent:local` | Container image tag to use |
| `MEMORY` | `4g` | Memory limit for the agent container |
| `INFERENCE_SERVER_HOST_IP` | `192.168.64.1` | Host-side IP of the inference server |
| `INFERENCE_SERVER_HOST_PORT` | `8080` | Port of the inference server |
| `GRADLE_WARMUP_SCRIPT` | `scripts/gradle-warmup.sh` | Custom warmup script path |
| `EGRESS_PROXY_IP` | *(auto-detected)* | The proxy's IP on the active network (sandboxed or default, depending on `--with-internet`); exposed as an env var inside the container |
| `PROVIDER_API_KEY` | `not-required` | API key for your local inference server. Substituted into `models.json` at launch time. Set this when your server requires authentication; leave unset for servers like `llama-server` that don't. |
| `OPENROUTER_API_KEY` | *(required with `--openrouter`)* | OpenRouter API key. Passed into the container only when `--openrouter` is used. |

> **Fish wrapper variables** (used by the `pi-agent` convenience wrapper, not `run.sh` itself):
>
>| Variable | Default | Description |
>|---|---|---|
>| `PI_SANDBOX_RUN_SCRIPT` | *(required)* | Path to `scripts/run.sh` |
>| `PI_SANDBOX_DEFAULT_MODEL_OPENROUTER` | *(none)* | Default model when using `--openrouter` |

# Troubleshooting

**Egress proxy not healthy / agent can't reach inference server.** Check that the inference server is actually listening on `192.168.64.1:8080` and that `egress-proxy` is running (`container list`).

**Gradle warmup warnings.** These are normal if your project currently has compile errors. The agent can still run — the warmup just pre-downloads dependencies when it can.

**Stale `egress-proxy` container.** The proxy persists across runs and is shared by parallel sessions. Remove it with `container rm -f egress-proxy` if needed; the next `run.sh` invocation will recreate it.

# Appendix

## Gradle warmup

If your project has a `gradlew`, `run.sh` pre-downloads Gradle dependencies on the `default` network before launching the sandboxed agent. The cache lives at `~/.pi-container-gradle/<project-name>` on the host. The warmup always uses `--cpus 4 --memory 4g` (JVM builds need more headroom than the agent run). Set `GRADLE_WARMUP_SCRIPT` to use a custom script.

To prevent path pollution between the container and your Mac, Gradle metadata is fully isolated: both `GRADLE_USER_HOME` (dependency cache) and the project's own `.gradle/` directory (task artifacts, Spotless hashes) are mounted from container-dedicated directories. This means the host's Gradle never sees container-written paths like `/projects/...`, avoiding "target files must be within project dir" errors.

## Egress proxy lifecycle

The `egress-proxy` container (a `socat` forwarder) is started once and persists across `run.sh` invocations. Parallel agent sessions share the same proxy. It is not torn down when a session ends — remove it manually with `container rm -f egress-proxy` if needed.

## APPEND_SYSTEM.md

The file `pi-config/APPEND_SYSTEM.md` is appended to pi's system prompt at runtime. When running in sandboxed mode (without `--with-internet`), a "no internet access" notice is automatically appended to it. Edit this file to add custom instructions for the agent.

## Fish shell convenience wrapper

Optional fish-only wrapper that lets you run `pi-agent` from any project directory.

First, set global variables (adjust the paths and model as needed):

```fish
set -U PI_SANDBOX_RUN_SCRIPT ~/path/to/pi-container/scripts/run.sh
set -U PI_SANDBOX_DEFAULT_MODEL_OPENROUTER openrouter/deepseek/deepseek-v4-flash-0731
```

- `PI_SANDBOX_DEFAULT_MODEL_OPENROUTER` — default model when using `--openrouter` (local runs don't need one — pi falls back to `llama-local/current` on its own)

Then copy the wrapper function into your fish functions directory:

```fish
cp scripts/fish/pi-agent.fish ~/.config/fish/functions/pi-agent.fish
```

After that, you can run `pi-agent` from any project directory:

```fish
cd ~/my-project
pi-agent                          # sandboxed run with the local model
pi-agent --openrouter --with-internet   # runs with the default OpenRouter model
pi-agent --shell                  # drops into a debugging shell
pi-agent --with-internet          # runs with full internet access
pi-agent --model other-model      # use a specific model for this call
```

The script lives in `scripts/fish/` so other wrappers (e.g. for different agents) can coexist without cluttering the README.

# Credits

Originally based on [michaelhannecke/pi-container](https://github.com/michaelhannecke/pi-container) (MIT). Redesigned for network sandboxing.
