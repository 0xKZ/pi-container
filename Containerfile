# Pi Coding Agent inside an Apple container.
#
# Minimal Node image; pi installed globally, tools for the
# bash tool-call (find, grep, rg) available, /workspace as the
# mount target for the respective project.

FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      curl \
      git \
      fd-find \
      ripgrep \
      ca-certificates \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

# Pinned deliberately -- avoid auto-upgrading to a version that might
# change behavior we've already tuned our workflow around.
ARG PI_VERSION=0.79.6

# "--ignore-scripts" is suggested by the pi documentation itself.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}

ARG PI_UID=1000
ARG PI_GID=1000
# node:22 already ships a 'node' user/group at UID/GID 1000; remove it so the
# 'pi' user can own that id range, then create pi.
RUN userdel --remove node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid ${PI_GID} pi \
 && useradd --uid ${PI_UID} --gid ${PI_GID} --create-home --shell /bin/bash pi

USER pi
WORKDIR /workspace

# Set environment variables for pi here.
#
# This one avoids telemetry and update checks on pi startup.
ENV PI_OFFLINE=1

# pi reads ~/.pi/agent/* at runtime; the directory is mounted via a volume.
ENTRYPOINT ["pi"]
