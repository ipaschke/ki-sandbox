# Agent sandbox

Docker + devcontainer CLI sandbox for running `claude` and `codex` against a
project directory with a default-deny egress firewall.

## Install

    ./install.sh --build

Installs docker.io (apt, admin password via pkexec), enables the service,
adds you to the `docker` group, installs `@devcontainers/cli` (npm, prefix
switched to `~/.local` if the global one is not writable), links the
`sbx-*` shims into `~/.local/bin`, adds a GTK CSS rule so Ptyxis shows a
green header bar for sandbox windows, and builds the image. Re-run any
time; each step is skipped when already done. After a fresh docker group
add: `newgrp docker` or re-login. Flags: `--no-docker`, `--no-gtk`.

Layout:

    install.sh                     this installer
    sbx                            wrapper (all sbx-* shims call it)
    seed-config.sh                 copies host claude/codex config into the volumes
    sbx-git.py                     host side of git approval (terminal and web UI)
    tests/run.sh                   test suite, no docker needed
    .devcontainer/Dockerfile       image: Ubuntu 24.04, node 22, claude, codex, build tools
    .devcontainer/devcontainer.json  mounts, caps, firewall hook
    .devcontainer/init-firewall.sh egress allowlist (iptables + ipset)
    .devcontainer/git-wrapper.sh   /usr/local/bin/git in the image: push/fetch/pull -> request

    sbx-claude  [project-dir] [claude args...]
    sbx-codex   [project-dir] [codex args...]
    sbx-shell   [project-dir] [bash args...]
    sbx-git     [project-dir]      # review and run the agent's git push/fetch/pull requests
    sbx-git --serve                # web UI for all projects on http://127.0.0.1:7331 (autostarted by sbx-*)
    sbx-seed    [project-dir]      # re-copy host auth/config into the sandbox
    sbx-stop    [project-dir]      # remove that project's container
    sbx-rebuild [project-dir]      # rebuild image (after editing Dockerfile)
    sbx-ps                         # list sandbox containers

`project-dir` defaults to the current directory and is bind-mounted at
its own host path (e.g. `/home/ipaschke/Source/llvm-project`), so absolute
and relative paths match the host. Nothing else from the host is visible.
Home inside the container is `/home/dev`, not `/home/ipaschke`, so `~` differs.
One container per project directory; containers persist until `sbx-stop`.

Auth and settings live in docker volumes `sandbox-claude-config` and
`sandbox-codex-config`, shared across projects. On first use they are
seeded from the host by `seed-config.sh`: claude credentials, CLAUDE.md,
agents/commands/skills, keybindings, settings.json (minus hooks, plugins,
statusLine, which point at host-only tools), onboarding flags, and codex
auth.json. Later host changes are not synced; run `sbx-seed` to re-copy.
Host `~/.claude` / `~/.codex` are never bind-mounted.

Container user `dev` is uid 1000 (same as host user), no sudo except the
firewall script (without arguments). Files written to mounted directories
appear on the host owned by you.

Claude Code's approval bypass (`--dangerously-skip-permissions`,
`bypassPermissions`) and auto mode are disabled inside the container by
`/etc/claude-code/managed-settings.json`, baked into the image. Managed
settings win over user and project settings, and `dev` cannot edit them.

Per-project sandbox config (extra mounts, extra egress) lives on the host
under `~/.config/sbx/projects/<project path with / replaced by ->/`, never
inside the project: the agent has write access to the project, so a file
there would let it, or a cloned repo, widen its own sandbox. Legacy
`.sandbox-mounts` / `.sandbox-allow` files inside a project are ignored
with a warning.

## Mounting directories

What the container sees:

| Path inside container            | Source                          | Mode |
|----------------------------------|---------------------------------|------|
| `<project-dir>` (same host path) | bind mount of the project       | rw   |
| extra dirs (same host path)      | `~/.config/sbx/projects/<p>/mounts`, `SBX_MOUNTS` | rw or ro |
| `/etc/sbx`                       | `~/.config/sbx/projects/<p>/` (only if `allow` exists) | ro |
| `/home/dev/.claude`              | volume `sandbox-claude-config`  | rw   |
| `/home/dev/.codex`               | volume `sandbox-codex-config`   | rw   |
| `/home/dev/.bash_history_dir`    | volume `sandbox-bash-history`   | rw   |

Everything else is the image: no host `$HOME`, no `/tmp`, no other repos.

### Per-project mount list

Create `~/.config/sbx/projects/<p>/mounts`, where `<p>` is the absolute
project path with every `/` replaced by `-` (for
`/home/ipaschke/Source/llvm-project` that is
`-home-ipaschke-Source-llvm-project`). One host path per line; `~` expands
to your home, `#` starts a comment, `:ro` suffix mounts read-only:

    # sibling repos needed by the build
    ~/Source/transputer
    ~/Source/llvm-test-suite
    # toolchain, never written
    /opt/sysroot:ro

Paths must exist on the host (the wrapper refuses missing ones). They
appear inside at the same absolute path, so relative paths like
`../transputer` from the project work exactly as on the host.

The file is deliberately not part of the project, so it is not committed
and not shared through the repo. The wrapper also refuses to start if the
config directory itself would end up inside a writable mount (for example
when mounting `~` as the project); mount such a tree `:ro` or point
`XDG_CONFIG_HOME` elsewhere.

### One-off mounts

Whitespace-separated `SBX_MOUNTS` adds to (does not replace) the file:

    SBX_MOUNTS="~/scratch /mnt/data:ro" sbx-claude

### Behaviour

- Mounts are fixed when a container is created. Changing the list
  (file or env) makes the next `sbx-*` call print
  `sbx: config changed, recreating container` and start fresh. Running
  processes in the old container are killed; the volumes survive.
- The extra mounts are written into a generated
  `.devcontainer/gen/<hash>/devcontainer.json` (the devcontainer CLI's
  `--mount` flag has no read-only option). The directory is disposable.
- Symlinks inside a mounted directory that point outside it are dangling
  in the container. Mount the target too.
- To mount a whole tree of projects, mount the parent and run
  `sbx-claude ~/Source` then `cd` inside; you get one container for all
  of them.
- Docker volumes can be inspected from the host with
  `docker run --rm -v sandbox-claude-config:/v alpine ls -la /v`.

## Network

### Default policy

`init-firewall.sh` runs as root at every container start
(`postStartCommand`) and installs iptables rules:

- `OUTPUT` default `DROP`; only DNS, loopback, the docker bridge subnet,
  established connections, and destinations in the `allowed-domains`
  ipset get through. Everything else is rejected with
  `icmp-admin-prohibited`, so blocked connections fail fast instead of
  hanging.
- `INPUT` default `DROP` except loopback, DNS replies, the bridge subnet,
  and established connections.
- The script verifies itself: `example.com` must be unreachable and
  `api.github.com` reachable, otherwise the container start fails.

Allowed by default (see `ALLOW_DOMAINS` in the script): Anthropic and
OpenAI APIs, GitHub (all published IP ranges via `api.github.com/meta`),
npm, PyPI, nodesource, Ubuntu archives.

### Allowing more destinations

Per project: `~/.config/sbx/projects/<p>/allow` (same `<p>` as for
`mounts`), one entry per line, `#` comments. The wrapper bind-mounts the
directory read-only at `/etc/sbx`; the firewall script reads
`/etc/sbx/allow` only if that mount really is read-only, so nothing the
container user can write ever reaches the allowlist. Entries are hostnames
(resolved to IPv4 at container start) or raw IPv4 addresses / CIDRs:

    # crates.io for cargo
    crates.io
    static.crates.io
    index.crates.io
    # internal artifact server
    10.20.0.15
    192.168.1.0/24

For everyone: edit `ALLOW_DOMAINS` in `.devcontainer/init-firewall.sh`
and run `sbx-rebuild` (the script is baked into the image).

Changes take effect on the next container start:

    sbx-stop && sbx-claude

### Limitations and how to work around them

- Names are resolved once, at start. CDN-backed hosts that rotate IPs
  (large `cloudfront`/`fastly` pools) may fail later; `sbx-stop` and
  restart re-resolves. Add the CIDR instead if the provider publishes one.
- IPv4 only. The container has no IPv6 route by default, so this is not
  a hole.
- Only IPs are matched, not ports or hostnames. Allowing a host allows
  every port on it.
- The allowlist cannot express "all of AWS" and is not meant to. If an
  agent needs unrestricted network for a task, run that task on the host.

### Talking to the host

The docker bridge subnet (`172.17.0.0/24` by default) is allowed in both
directions, so:

- Services on the host bound to `0.0.0.0` or the bridge IP are reachable
  from inside at the gateway address, usually `172.17.0.1`
  (`ip route | awk '/default/ {print $3}'` inside the container). Services
  bound only to `127.0.0.1` on the host are not reachable.
- A server started inside the container (e.g. `python -m http.server`) is
  reachable from the host at the container's IP:
  `docker inspect -f '{{.NetworkSettings.IPAddress}}' $(docker ps -q --filter label=sbx.project=$PWD)`.
  No ports are published, so nothing is exposed beyond this machine.

### Disabling the firewall

Not recommended, but for a one-off: remove `postStartCommand` from
`.devcontainer/devcontainer.json`, then `sbx-stop` and start again. The
container then has whatever network docker's default bridge gives it.
Put it back afterwards; `git diff` will remind you.

## Git: remote operations run on the host

The container holds no git credentials, no `gh` and no SSH keys, so the
agent can commit but cannot push, fetch or pull. Instead of failing
silently, those three operations become approval requests that the
developer executes on the host, with the host's credentials, after
reviewing them. Everything else (`commit`, `branch`, `rebase`, `clone` of
public repos) runs inside as before. The wrapper is convenience, not the
security boundary: `/usr/bin/git push` called directly still fails for
lack of credentials.

### Flow

1. Inside the container `/usr/local/bin/git` (first on PATH) forwards
   every command to `/usr/bin/git` except `push`, `fetch` and `pull`.
   For those it writes a request file to `/run/sbx/requests/`, prints
   where to approve it, and exits non-zero so the agent cannot believe
   the push happened.
2. `/run/sbx/requests` is a read-write bind mount of
   `~/.local/state/sbx/projects/<p>/requests/` on the host. Subfolders
   `done/` and `rejected/` receive the outcome, so the agent can read it.
3. On the host, `sbx-git [project-dir]` lists pending requests with a
   preview (for `push`: commits and `diff --stat` against the remote
   branch, remote URL; for `fetch`/`pull`: the command and `status -sb`)
   and asks yes / no / skip. Yes runs `git -C <cwd> <op> <args>` on the
   host and records exit code and output.
4. Alternatively the same review runs in a browser: `sbx-*` shims start
   a small web server on `http://127.0.0.1:7331` if none is running
   (`sbx-git --serve` runs it in the foreground). The container prints
   `http://127.0.0.1:7331/r/<id>` with every request. The server is
   bound to loopback, which the container cannot reach (the firewall
   only opens the docker bridge address of the host), so the agent can
   show the link but never click it.

### Validation on the host

A request is data written by the agent. Before anything runs:

- operation must be `push`, `fetch` or `pull`;
- the working directory must lie inside the project (or one of its
  configured extra mounts) and be a git work tree;
- the remote must be a remote *name* configured in that repo, never a
  URL or path; the remote URL is shown in the preview, and hosts other
  than github.com are flagged;
- `push` refuses `--force`, `-f`, `--force-with-lease`, `--delete`,
  `-d`, `--mirror`, `--prune`, `+refspec` and `:branch` deletion specs.

Anything that fails validation is moved to `rejected/` with the reason.

### Web server safety

Approve and reject are POST only, with a token generated at server start
and embedded only in the server's own pages; `Host` and `Origin` headers
must point at loopback. A foreign website open in the same browser
cannot trigger a push. Git runs with `GIT_TERMINAL_PROMPT=0`, so the web
path needs a non-interactive credential source (ssh-agent, credential
helper); the terminal path can still prompt.

### Files

    .devcontainer/git-wrapper.sh   installed as /usr/local/bin/git in the image
    sbx-git.py                     host side: validation, preview, terminal UI, web UI
    tests/                         run ./tests/run.sh (no docker needed)

## Terminal colour

Ptyxis colours its header bar by the foreground process name (`ssh` blue,
`sudo` red). `docker` gets a `.container` class with no default colour;
`install.sh` adds a green rule to `~/.config/gtk-4.0/gtk.css`. `sbx` must
`exec docker` (not run it as a child) for this to trigger. foot has no
equivalent.

## Gotchas learned the hard way

- `devcontainer exec` cannot pass dash-prefixed args (yargs eats them), so
  `sbx` uses `docker exec` directly, keyed by container label.
- `devcontainer up --mount` cannot express `readonly`; extra mounts go
  through a generated `devcontainer.json` under `.devcontainer/gen/`.
- The override config must be named `devcontainer.json`.
- Named volumes inherit ownership from the image directory they cover, so
  `mkdir` as the target user in the Dockerfile avoids chown at start.
- Claude keys sessions by cwd; changing the mount path orphans old sessions
  under `~/.claude/projects/<old-path>/` (rewrite `cwd` and move them).
