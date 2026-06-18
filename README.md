
# What this is

A wrapper that configures an Apple container that it then runs a pi coding agent on.

# Usage

## Build the VM image (only need to do this once, on the host machine):

`./scripts/build.sh`


## Verifying the network sandbox

Before trusting the agent with real work, confirm the network boundary is actually doing what it's supposed to: blocking the open internet while still allowing access to the local inference server.

Drop into a shell with the same network and mounts the agent would get:

```bash
./scripts/run.sh --shell
```

From inside that shell, run these three checks:

```bash
# 1. Open internet should be UNREACHABLE
curl --max-time 5 https://www.google.com/

# 2. The real inference server's host-side address should also be UNREACHABLE
#    (the agent should only ever reach it through the proxy, never directly)
curl --max-time 5 http://192.168.64.1:8080

# 3. The egress proxy should be REACHABLE, and should return a response
#    from the inference server
curl http://$EGRESS_PROXY_IP:8080
```

What you should see: the first two commands time out or fail to connect (`curl: (28) Connection timed out` or similar), and the third one succeeds, returning whatever response the inference server gives for a bare request to its root path.

If check 1 or 2 unexpectedly succeeds, the sandbox isn't isolating the container — stop and investigate before running the agent on anything sensitive. If check 3 fails, the proxy itself isn't working; check that `egress-proxy` is running (`container list`) and that the inference server is actually listening on `192.168.64.1:8080` on the host.

## Running the agent

Now that we are confident that the network restriction is working properly, we can spawn an agent to do some work.

Try:
```
PROJECT_DIR=~/development/my_project_directory ./scripts/run.sh --model llama-local/Qwen3.6-27B
```

### Notes on llama-server

When I host on llama-server I need a `--host` argument. Using `0.0.0.0` works but exposes the server to everything on your LAN. 

TODO: better instructions here

## Convenience: easily launching session on the host mac

I use fish shell, so these instructions are for fish shell.

First, set a global variable so that the run script of this repo can be found anywhere. This only has to be run once and it will be saved by fish.

```
set -U PI_SANDBOX_RUN_SCRIPT ~/path/to/pi-container/scripts/run.sh
```

Also save the default model so you don't have to provide it all the time:
```
set -U PI_SANDBOX_DEFAULT_MODEL llama-local/Qwen3.6-27B
```

When you upgrade models, simply swap that command, or temporarily provide the `--model` argument for one-offs.


Next, add the fish function as a new file at `~/.config/fish/functions/pi-agent.fish`:

```
function pi-agent --description "Run pi-coding-agent sandboxed, using the current directory as the project"
    if not set -q PI_SANDBOX_RUN_SCRIPT
        echo "PI_SANDBOX_RUN_SCRIPT is not set. Run: set -U PI_SANDBOX_RUN_SCRIPT /path/to/run.sh" >&2
        return 1
    end

    if not test -x "$PI_SANDBOX_RUN_SCRIPT"
        echo "PI_SANDBOX_RUN_SCRIPT points at '$PI_SANDBOX_RUN_SCRIPT', which doesn't exist or isn't executable." >&2
        return 1
    end

    set -l args $argv

    # Only inject the default model if the caller didn't already pass
    # --model themselves -- lets you override per-call without editing
    # any config, e.g. `pi-agent --model some-other-model`.
    # Append at the end (not prepend) so that run.sh's arg parser sees
    # user-provided flags like --with-internet before hitting --model.
    if set -q PI_SANDBOX_DEFAULT_MODEL
        if not contains -- --model $args
            set args $args --model $PI_SANDBOX_DEFAULT_MODEL
        end
    end

    PROJECT_DIR="$PWD" "$PI_SANDBOX_RUN_SCRIPT" $args
end
```

Now you are good to go. Simply run `pi-agent` inside of the directory of whatever project you want the agent to work in, and a container will be spun up to do so. Use `pi-agent --shell` to launch into a terminal instead of the agent for testing the networking sandbox (upon updating container versions for example).

### Running with internet access

Use `pi-agent --with-internet` to launch the container on the `default` network with full internet access. This also skips the Gradle warmup step since the container can download dependencies on its own.

# Original inspiration

Originally based on https://github.com/michaelhannecke/pi-container

^ I didn't like how that repo allowed internet access to the agent, I wanted to go a step further and run it sandboxed and firewalled. It also has some other out of date things, like the version of pi it's built for is old, so the extension breaks the pi tools if you try to use it, among other things. Basically just documenting my original inspiration here.
