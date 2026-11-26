# megavibe dispatch in a container: one dispatcher plus one session per GitHub issue, in tmux, as a non-root user
# (Claude Code refuses --dangerously-skip-permissions as root, and the issue sessions run with it).
# Build from the repository root:  docker build -f docker/Dockerfile -t megavibe-dispatch .
FROM node:22-bookworm-slim

# Pinned: the issue sessions run with permissions bypassed, so a moving "latest" is a moving supply chain. Bump it on purpose
# (--build-arg CLAUDE_CODE_VERSION=...). The base image is a tag, not a digest: pin it to one you have vetted for production use.
ARG CLAUDE_CODE_VERSION=2.1.332
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends git tmux jq perl curl ca-certificates gnupg uuid-runtime procps openssh-client \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# the node image ships a user "node" (uid 1000): use it, with the home and work directories the compose file mounts
RUN usermod -l mv -d /home/mv -m node && groupmod -n mv node \
 && mkdir -p /work /opt/megavibe && chown mv:mv /work /opt/megavibe

COPY --chown=mv:mv . /opt/megavibe
COPY --chown=mv:mv docker/entrypoint.sh /usr/local/bin/megavibe-entrypoint
RUN chmod 0755 /usr/local/bin/megavibe-entrypoint

USER mv
ENV HOME=/home/mv \
    PATH=/home/mv/.local/bin:/usr/local/bin:/usr/bin:/bin \
    TERM=xterm-256color \
    MEGAVIBE_STYLE=1
WORKDIR /work

# megavibe's own installer, from the copy above: it installs the scripts, the protocol and the launcher under ~/.megavibe
# and ~/.local/bin; no TTY, so no prompts. The image keeps a pristine copy: the entrypoint re-runs it when the volume is empty.
RUN bash /opt/megavibe/setup.sh --auto-install </dev/null >/tmp/setup.log 2>&1 || { tail -40 /tmp/setup.log; exit 1; }; \
    rm -f /tmp/setup.log; command -v megavibe >/dev/null

ENTRYPOINT ["/usr/local/bin/megavibe-entrypoint"]
