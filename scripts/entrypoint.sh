#!/usr/bin/env bash
# Runs pi with whatever args were passed at `container run` time. When pi
# exits (normal quit, error, whatever), drop into an interactive bash shell
# inside the same still-running VM instead of letting the container exit.
# Only exiting that shell (or running `exit`) actually tears down the VM.
#
# We don't `set -e` here on purpose -- a non-zero exit from pi (e.g. user
# hit an error and quit) should still land you in bash, not kill the
# container.


# pi reads ~/.pi/agent/* at runtime; the directory is mounted via a volume.
pi "$@"
PI_EXIT_CODE=$?

echo "" 
echo "pi exited (code ${PI_EXIT_CODE}). Dropping into a shell -- exit this to stop the container (note: will wipe your pi sessions)."
echo ""


# Custom prompt so this shell is easy to spot among many open terminal
# windows/sessions. PROJECT_NAME is passed in from run.sh via --env, since
# this container only sees /workspace, not the host path or its name.
export PS1="(AGENT-SANDBOX-${PROJECT_NAME:-unknown}) \w \$ "

exec bash --norc
