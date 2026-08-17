function pi-agent --description "Run pi-coding-agent sandboxed, using the current directory as the project"
    if not set -q PI_SANDBOX_RUN_SCRIPT
        echo "PI_SANDBOX_RUN_SCRIPT is not set. Run: set -U PI_SANDBOX_RUN_SCRIPT /path/to/run.sh" >&2
        return 1
    end

    if not test -x "$PI_SANDBOX_RUN_SCRIPT"
        echo "PI_SANDBOX_RUN_SCRIPT points at '$PI_SANDBOX_RUN_SCRIPT', which doesn't exist or isn't executable." >&2
        return 1
    end

    # Args are passed through as-is. Model defaults are handled by run.sh
    # itself: with --openrouter it injects PI_SANDBOX_DEFAULT_MODEL_OPENROUTER
    # if set (and errors if neither that nor --model is available), and for
    # local runs pi falls back to the single configured model
    # (llama-local/current in models.json) when --model is not given.
    PROJECT_DIR="$PWD" "$PI_SANDBOX_RUN_SCRIPT" $argv
end

