#!/usr/bin/env bash
# Runs pi with whatever args were passed at `container run` time. When pi
# exits (normal quit, error, whatever), drop into an interactive bash shell
# inside the same still-running VM instead of letting the container exit.
# Only exiting that shell (or running `exit`) actually tears down the VM.
#
# We don't `set -e` here on purpose -- a non-zero exit from pi (e.g. user
# hit an error and quit) should still land you in bash, not kill the
# container.
#
# Detached mode: if DETACH_MODE is set, the container was launched in
# headless mode. Pi runs and the container exits when it finishes
# (no debug shell).
# Prompt file: if PROMPT_FILE is set, pi is started with that prompt
# (works in both detached and interactive modes).

# --- Display setup ---
# If DISPLAY_MODE=xvfb, start a virtual framebuffer (Xvfb) so that graphics
# operations (game rendering, screenshot tests, etc.) have a display to use.
# This runs headlessly — no actual window appears on the host Mac.
# If DISPLAY_MODE=x11, the host's XQuartz socket is already mounted and
# DISPLAY is set; nothing extra to do here.
if [ "${DISPLAY_MODE}" = "xvfb" ]; then
    Xvfb "${DISPLAY:-:99}" -screen 0 1920x1080x24 &
    XVFB_PID=$!
    # Wait briefly for Xvfb to be ready
    for i in 1 2 3 4 5; do
        if xdpyinfo >/dev/null 2>&1; then break; fi
        sleep 0.2
    done
fi

# Navigate to the project-specific directory so pi's footer and terminal
# title show the project name instead of a generic "/workspace".
# PROJECT_NAME is passed in from run.sh via --env.
if [ -n "${PROJECT_NAME}" ] && [ -d "/projects/${PROJECT_NAME}" ]; then
    cd "/projects/${PROJECT_NAME}"
fi

# Run pi, optionally with a prompt file.
if [ -n "${PROMPT_FILE}" ] && [ -f "${PROMPT_FILE}" ]; then
    pi "$@" -p "@${PROMPT_FILE}"
else
    pi "$@"
fi
PI_EXIT_CODE=$?

# Detached mode: exit when pi finishes (no debug shell).
if [ "${DETACH_MODE}" = true ]; then
    exit $PI_EXIT_CODE
fi

echo ""
echo "pi exited (code ${PI_EXIT_CODE}). Dropping into a shell -- exit this to stop the container."
echo ""


# Custom prompt so this shell is easy to spot among many open terminal
# windows/sessions. PROJECT_NAME is passed in from run.sh via --env, since
# this container only sees /projects/<name>, not the host path.
export PS1="(AGENT-SANDBOX-${PROJECT_NAME:-unknown}) \w \$ "

exec bash --norc
