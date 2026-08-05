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

    # Only inject a default model if the caller didn't already pass
    # --model themselves -- lets you override per-call without editing
    # any config, e.g. `pi-agent --model some-other-model`.
    if not contains -- --model $args
        # --openrouter without --model: inject PI_SANDBOX_DEFAULT_MODEL_OPENROUTER
        # right after --openrouter so run.sh's arg parser sees them together.
        if set -q PI_SANDBOX_DEFAULT_MODEL_OPENROUTER
            if contains -- --openrouter $args
                set -l openrouter_idx
                for idx in (seq (count $args))
                    if test $args[$idx] = "--openrouter"
                        set openrouter_idx $idx
                        break
                    end
                end
                set args $args[1..$openrouter_idx] --model $PI_SANDBOX_DEFAULT_MODEL_OPENROUTER $args[(math $openrouter_idx + 1)..-1]
            end
        end

        # If no model was injected, append PI_SANDBOX_DEFAULT_MODEL at the end
        # so that run.sh's arg parser sees user-provided flags like --with-internet
        # before hitting --model.
        # BUT: if --openrouter is active, do NOT inject the local default model.
        # Let run.sh handle the openrouter/ default instead of accidentally
        # passing a llama-local/ model into an OpenRouter run.
        # (Re-check --model here because $args may have been modified by the
        #  OpenRouter injection block above — if it injected --model, skip this.)
        if not contains -- --model $args
            if not contains -- --openrouter $args
                if set -q PI_SANDBOX_DEFAULT_MODEL
                    set args $args --model $PI_SANDBOX_DEFAULT_MODEL
                end
            end
        end
    end

    PROJECT_DIR="$PWD" "$PI_SANDBOX_RUN_SCRIPT" $args
end

