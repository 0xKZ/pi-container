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

