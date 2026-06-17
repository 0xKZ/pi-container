
Originally based on https://github.com/michaelhannecke/pi-container

^ That repo has a full readme, I cleared this out to minimize it.

There was an accompanying blog post. I archived that in the repo as a PDF. I am not sure how much of the blog post or the repo is vibed/slop (Some red flags, like it being written in May 2026 but recommending an old model, plus some of the language. However the repo has a reasonably new model so I think it was someone that maybe vibed half of the article?). So, this repo is a starting point for me to test it out, and if I end up having success with it, I will continue to modify and use.


Note the original code is unlicensed, so I can't embed this code directly in any project, would have to start fresh. Just keep in mind.

My changes so far:
- slimmed down the agents file, converted to english.
- rewrote the script to add all the network security, as the original guide still had the agent exposed to the internet
- rewrote the readme

---

# Usage

NOTE: at the time of writing this https://github.com/apple/container/discussions/719 is not resolved. In the future, apple container may have more easily built in ways of firewalling internet traffic. If such a feature gets added, look into simplifying this.

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
