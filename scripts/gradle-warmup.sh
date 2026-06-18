#!/usr/bin/env bash
# Default Gradle warmup script. Runs the build and spotlessApply,
# ignoring exit code 1 (which can happen from compile errors or
# formatting failures -- the agent will fix those).
#
# Override with GRADLE_WARMUP_SCRIPT env var in run.sh.

# Build (skip tests, continue past failures)
./gradlew --stacktrace --continue build -x test || true

# Apply code formatting
./gradlew --stacktrace spotlessApply || true
