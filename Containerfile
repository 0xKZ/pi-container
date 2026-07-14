# Pi Coding Agent inside an Apple container.
#
# Base: official Eclipse Temurin JDK image (built by the Eclipse Foundation,
# the same people who produce the JDK), with Node.js binaries copied in from
# the official Node image. pi is installed globally via npm, /workspace is
# the mount point for the project, and additional build tools are installed
# as needed.
#
# Both Java and Node come from their own official, purpose-built images.
# This avoids the need to configure any third-party package repositories.
# --------------------------------------------------------------------------

# This first FROM is a *build-stage-only* source of Node.js binaries. It is
# never run, never shipped, and doesn't become part of the final image --
# we only use it a few lines down as something to COPY files FROM. This
# pattern is called a "multi-stage build": you can have multiple FROM lines
# in one Containerfile, and each one starts a fresh, independent stage.
# Only the LAST stage (the one without a name, or whichever you target)
# actually becomes the image you end up running.
FROM node:22-bookworm-slim AS node-source

# This is the base for our final image: Eclipse Temurin's official JDK
# image. It runs on Ubuntu 22.04 ("jammy"), which uses Debian-style apt
# packaging. All standard Debian/Ubuntu package names work as expected.
FROM eclipse-temurin:21-jdk-jammy

# --------------------------------------------------------------------------
# Bring Node.js + npm into this image by copying the binaries straight out
# of the node-source stage above. This keeps Node coming from its official
# image without needing a third-party repo or an install script.
# --------------------------------------------------------------------------
COPY --from=node-source /usr/local/bin/node /usr/local/bin/node
COPY --from=node-source /usr/local/lib/node_modules /usr/local/lib/node_modules

# The Node image ships npm/npx as JS files inside node_modules, with the
# actual `npm`/`npx` commands on PATH being symlinks into those files. We
# recreate those same symlinks here since we only copied the underlying
# node_modules directory above, not the original symlinks themselves.
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Sanity check: fail the BUILD immediately and loudly if any of these four
# runtimes aren't actually working, instead of finding out later via a
# confusing failure inside a running container. java/javac come from the
# base image directly; node/npm are the ones we just wired up above.
RUN java -version && javac -version && node -v && npm -v

# This is a collection of tools that the agent tends to want to work.
RUN apt-get update && apt-get install -y --no-install-recommends \
    zip unzip xz-utils bzip2 \
    jq \
    patch htop tmux \
    git ripgrep less vim \
    ffmpeg imagemagick \
    python3 python3-pip \
    gcc g++ clang make cmake \
    gdb strace \
    wget \
    xxd bsdmainutils file \
    tree bat fd-find \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

# Debian/Ubuntu ship the `fd` tool under the binary name `fdfind` (to avoid
# clashing with an unrelated, pre-existing `fd` command). We symlink it to
# the name `fd` so it matches what the agent (and most
# documentation/tutorials) expect.
RUN ln -s "$(which fdfind)" /usr/local/bin/fd

# Pinned deliberately -- avoid auto-upgrading to a version that might
# change behavior we've already tuned our workflow around.
ARG PI_VERSION=0.80.2

# "--ignore-scripts" is suggested by the pi documentation itself.
#
# After installing, we immediately check that the installed version
# actually matches what we asked for. This guards against a subtle failure
# mode: if the exact pinned version ever became unavailable/mismatched on
# npm for some reason, we'd rather the BUILD fail loudly here than silently
# end up running a different pi version than we intended.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION} \
    && installed_version="$(pi --version)" \
    && if [ "$installed_version" != "$PI_VERSION" ]; then \
         echo "ERROR: expected pi version ${PI_VERSION}, got ${installed_version}" >&2; \
         exit 1; \
       fi

ARG PI_UID=1000
ARG PI_GID=1000
# The eclipse-temurin base image does not pre-create a user at UID/GID 1000,
# so we create the 'pi' user and group from scratch.
RUN groupadd --gid ${PI_GID} pi \
 && useradd --uid ${PI_UID} --gid ${PI_GID} --create-home --shell /bin/bash pi

# Set environment variables for pi here.
#
# This one avoids telemetry and update checks on pi startup.
ENV PI_OFFLINE=1

# entrypoint.sh runs `pi`, and once pi exits (quit, error, whatever) drops
# you into an interactive bash shell INSIDE THE SAME STILL-RUNNING VM,
# instead of letting the container exit immediately. The VM only actually
# shuts down once you exit that bash shell too. This has to be copied and
# made executable BEFORE the `USER pi` line below -- root owns
# /usr/local/bin and the file inside it by default, and once we've switched
# to the non-root 'pi' user, that user no longer has permission to chmod
# files it doesn't own in a root-owned directory. The fix is ordering:
# anything needing root permissions must happen before USER switches away
# from root.
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Switch to the non-root 'pi' user LAST, after every step that needed root
# (apt-get installs, npm install -g, user creation, copying/chmod-ing
# entrypoint.sh). Everything below this line, and everything that happens
# at container *runtime*, runs as 'pi', not root.
USER pi
WORKDIR /projects

# Install Rust via rustup (latest stable) — edition 2024 requires rustc 1.85+.
# Ubuntu 22.04 apt ships rustc 1.75 which is too old.
# Run this as the 'pi' user so the install lands in /home/pi/.cargo/bin,
# which is fully accessible at runtime (avoids the /root permission trap).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --component clippy \
    && . "$HOME/.cargo/env" \
    && rustc -V && cargo -V && cargo clippy --version

ENV PATH="/home/pi/.cargo/bin:$PATH"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
