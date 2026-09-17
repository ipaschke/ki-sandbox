#!/usr/bin/env python3
"""sbx-git: review and run git remote operations requested from inside the sandbox.

    sbx-git.py --project DIR         terminal review of that project's pending requests
    sbx-git.py --serve [--port N]    web UI on http://127.0.0.1:N (default 7331), all projects

Requests are files written by the container's git wrapper into
~/.local/state/sbx/projects/<p>/requests/. They are untrusted data, and so is
the repository they refer to: the agent controls its hooks, its config and its
attributes. Therefore nothing that could execute code runs inside that
repository. An approved operation runs in a host-private shadow repository
that shares the agent's objects, carries only the validated remote URL and
plain data config (refspecs, branch tracking), and holds a snapshot of the
refs shown in the preview. Fetch results are copied back into the agent's
repository with plumbing commands and hooks disabled. For pull the host runs
only the fetch half; the container's git wrapper performs the merge or
rebase on the next `git pull`.

Remote URLs must point at an allowed host (~/.config/sbx/remote-hosts, default
github.com). The web UI refuses to run a request whose remote URL, refs or
arguments changed after the preview was shown.
"""
import argparse
import hashlib
import html
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

OPS = ("push", "fetch", "pull")
DEFAULT_PORT = 7331
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "sbx"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "sbx"
DEFAULT_REMOTE_HOSTS = ("github.com",)
REMOTE_HOSTS_FILE = CONFIG / "remote-hosts"
REMOTE_SCHEMES = ("https", "ssh", "git+ssh", "ssh+git")
# push options that rewrite or delete remote history
FORBIDDEN_PUSH = ("--force", "-f", "--force-with-lease", "--force-if-includes",
                  "--delete", "-d", "--mirror", "--prune", "--all")
# options that make git run a program on the host
FORBIDDEN_EXEC_PREFIXES = ("--receive-pack", "--exec", "--upload-pack", "-u", "--config")
# one remote per request: the shadow repository knows only that one
FORBIDDEN_MULTI = ("--all", "--multiple")
# pull options that belong to the fetch half (the merge half runs in the container)
PULL_FETCH_OPTS = ("--tags", "--no-tags", "--prune", "--no-prune", "--depth", "--deepen",
                   "--unshallow", "--update-shallow", "--progress", "--no-progress",
                   "-4", "-6", "--ipv4", "--ipv6", "-f", "--force", "-q", "--quiet",
                   "-v", "--verbose", "--dry-run")
# repository config the shadow repository takes over: data only, never commands
SHADOW_BRANCH_KEYS = re.compile(r"^branch\.[^\n]+\.(remote|merge|pushremote)$")
SHADOW_REMOTE_KEYS = ("url", "pushurl", "fetch", "push", "tagopt")
SHADOW_PLAIN_KEYS = ("push.default", "remote.pushdefault")
# settings that disable code execution when plumbing must touch the agent's repository
PIN = ("-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false")
# host environment that would redirect git to another repository
SCRUB_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
             "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CONFIG")


def project_key(project: Path) -> str:
    return str(project).replace("/", "-")


def requests_dir(project: Path) -> Path:
    return STATE / "projects" / project_key(project) / "requests"


@dataclass
class Request:
    path: Path
    reqdir: Path
    project: Path
    id: str = ""
    op: str = ""
    cwd: str = ""
    branch: str = ""
    head: str = ""
    time: str = ""
    args: list = field(default_factory=list)
    error: str = ""

    @property
    def command(self) -> str:
        return " ".join(["git", "-C", self.cwd, self.op] + self.args)


@dataclass
class Facts:
    """Everything the host needs from the agent's repository, gathered once per review."""
    cwd: Path
    gitdir: Path
    common: Path                    # shared git dir of the work tree (differs for linked worktrees)
    objects: Path
    head_ref: str                   # refs/heads/x, or "" when detached or unborn
    head_sha: str                   # "" when unborn
    refs: dict                      # refname -> sha, symbolic refs excluded
    config: list                    # (key, value) pairs of the repository config
    remote: str
    urls: list
    pushurls: list
    fingerprint: str = ""


def parse_request(path: Path, reqdir: Path, project: Path) -> Request:
    r = Request(path=path, reqdir=reqdir, project=project, id=path.stem)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        r.error = f"unreadable request: {e}"
        return r
    for line in text.splitlines():
        if ": " not in line:
            continue
        k, v = line.split(": ", 1)
        if k == "arg":
            r.args.append(v)
        elif k in ("op", "cwd", "branch", "head", "time"):
            setattr(r, k, v)
    if not r.op or not r.cwd:
        r.error = "malformed request (op or cwd missing)"
    return r


def allowed_roots(project: Path) -> list:
    roots = [project.resolve()]
    mounts = CONFIG / "projects" / project_key(project) / "mounts"
    if mounts.is_file():
        for line in mounts.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or line.endswith(":ro"):
                continue
            roots.append(Path(os.path.expanduser(line)).resolve())
    return roots


def inside(path: Path, roots: list) -> bool:
    return any(path == root or root in path.parents for root in roots)


# ---------------------------------------------------------------- git helpers
def hgit(*args, cwd=None, input=None, timeout: int = 60) -> subprocess.CompletedProcess:
    """git on the host, never pointed at the agent's repository by the environment."""
    env = {k: v for k, v in os.environ.items() if k not in SCRUB_ENV}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_PAGER="cat", PAGER="cat", GIT_EDITOR="true")
    return subprocess.run(["git", *args], cwd=cwd, input=input, capture_output=True, text=True,
                          env=env, timeout=timeout)


def agit(cwd: Path, *args, **kw) -> subprocess.CompletedProcess:
    """Read-only plumbing inside the agent's work tree, hooks and fsmonitor disabled."""
    return hgit("-C", str(cwd), *PIN, *args, **kw)


def agit_dir(gitdir: Path, *args, **kw) -> subprocess.CompletedProcess:
    """Plumbing on the agent's git dir, hooks and fsmonitor disabled."""
    return hgit("--git-dir", str(gitdir), *PIN, *args, **kw)


def sgit(shadow: Path, *args, **kw) -> subprocess.CompletedProcess:
    """git on the shadow repository."""
    return hgit("--git-dir", str(shadow), *args, cwd=str(shadow.parent), **kw)


def read_config(path: Path) -> list:
    """(key, value) pairs of a config file; parsing only, nothing is executed."""
    p = hgit("config", "--file", str(path), "--list", "-z")
    if p.returncode != 0:
        return []
    out = []
    for entry in p.stdout.split("\0"):
        if not entry:
            continue
        key, _, value = entry.partition("\n")
        out.append((key, value))
    return out


def config_get(config: list, key: str) -> str:
    vals = [v for k, v in config if k == key]
    return vals[-1] if vals else ""


def list_refs(p: subprocess.CompletedProcess) -> dict:
    refs = {}
    for line in p.stdout.split("\n"):
        parts = line.split("\0")
        if len(parts) == 3 and not parts[2]:   # skip symbolic refs
            refs[parts[1]] = parts[0]
    return refs


def refs_of(run, *prefix) -> dict:
    return list_refs(run("for-each-ref", "--format=%(objectname)%00%(refname)%00%(symref)", *prefix))


def split_args(args: list):
    """Return (options, positionals) for the recorded subcommand arguments."""
    opts, pos = [], []
    for a in args:
        (opts if a.startswith("-") else pos).append(a)
    return opts, pos


# ---------------------------------------------------------------- remote allowlist
def remote_rules() -> list:
    if REMOTE_HOSTS_FILE.is_file():
        rules = [l.strip() for l in REMOTE_HOSTS_FILE.read_text().splitlines()]
        return [r for r in rules if r and not r.startswith("#")]
    return list(DEFAULT_REMOTE_HOSTS)


def remote_host(url: str):
    """Return ("host", host), ("path", path) or (None, reason) for a remote URL."""
    if "://" in url:
        u = urllib.parse.urlparse(url)
        if u.scheme == "file":
            return "path", urllib.parse.unquote(u.path)
        if u.scheme not in REMOTE_SCHEMES:
            return None, f"scheme {u.scheme!r} is not allowed (use https or ssh)"
        if not u.hostname:
            return None, "URL has no host"
        return "host", u.hostname.lower()
    if url.startswith("/"):
        return "path", url
    m = re.match(r"^(?:[^@/]+@)?([^:/]+):", url)      # scp-like [user@]host:path
    if m:
        return "host", m.group(1).lower()
    return None, "remote is a relative path or an unknown transport"


def check_remote_url(url: str) -> str:
    """Empty string if the URL is allowed, else the reason."""
    kind, value = remote_host(url)
    if kind is None:
        return f"remote URL {url!r}: {value}"
    rules = remote_rules()
    if kind == "host":
        hosts = [r.lower() for r in rules if not r.startswith("/")]
        if any(value == h or value.endswith("." + h) for h in hosts):
            return ""
        return f"remote host {value!r} is not allowed (allowed: {', '.join(hosts) or 'none'}; edit {REMOTE_HOSTS_FILE})"
    prefixes = [r for r in rules if r.startswith("/")]
    resolved = str(Path(value).resolve()) if os.path.exists(value) else value
    if any(value.startswith(p) or resolved.startswith(p) for p in prefixes):
        return ""
    return f"local remote {value!r} is not allowed (no matching path prefix in {REMOTE_HOSTS_FILE})"


# ---------------------------------------------------------------- inspection
def inspect(r: Request):
    """Validate the request against the repository. Returns (Facts, "") or (None, reason)."""
    if r.error:
        return None, r.error
    if r.op not in OPS:
        return None, f"operation {r.op!r} is not one of {', '.join(OPS)}"
    try:
        cwd = Path(r.cwd).resolve(strict=True)
    except OSError:
        return None, f"working directory {r.cwd} does not exist on the host"
    roots = allowed_roots(r.project)
    if not inside(cwd, roots):
        return None, f"working directory {cwd} lies outside the project and its extra mounts"
    p = agit(cwd, "rev-parse", "--is-inside-work-tree", "--absolute-git-dir", "--git-common-dir", "--git-path", "objects")
    lines = p.stdout.splitlines()
    if p.returncode != 0 or len(lines) != 4 or lines[0] != "true":
        return None, f"{cwd} is not a git work tree"
    gitdir = Path(lines[1]).resolve()
    common = (cwd / lines[2]).resolve()
    objects = (cwd / lines[3]).resolve()
    for d in (gitdir, common, objects):
        if not inside(d, roots):
            return None, f"git directory {d} lies outside the project and its extra mounts"
    if (objects / "info" / "alternates").exists():
        return None, f"{objects}/info/alternates exists: repositories borrowing objects from elsewhere are not accepted"
    config = read_config(common / "config")

    opts, pos = split_args(r.args)
    for o in opts:
        name = o.split("=", 1)[0]
        if name.startswith(FORBIDDEN_EXEC_PREFIXES):
            return None, f"option {o} would run a program on the host"
        if name in FORBIDDEN_MULTI and r.op != "push":
            return None, f"option {o} addresses several remotes; request one remote at a time"
        if name.startswith("--recurse-submodules") and o not in ("--recurse-submodules=no",):
            return None, f"option {o} would contact submodule remotes"
        if r.op == "push":
            if name in FORBIDDEN_PUSH or name.startswith("--force"):
                return None, f"push option {o} rewrites or deletes remote history"
            if not o.startswith("--") and any(c in o[1:] for c in "fd"):
                return None, f"push option {o} combines -f or -d"
    if r.op == "push":
        for spec in pos[1:]:
            if spec.startswith("+"):
                return None, f"refspec {spec} forces the update"
            if spec.startswith(":"):
                return None, f"refspec {spec} deletes a remote branch"

    p = agit(cwd, "symbolic-ref", "-q", "HEAD")
    head_ref = p.stdout.strip() if p.returncode == 0 else ""
    p = agit(cwd, "rev-parse", "-q", "--verify", "HEAD")
    head_sha = p.stdout.strip() if p.returncode == 0 else ""
    branch = head_ref[len("refs/heads/"):] if head_ref.startswith("refs/heads/") else ""

    remotes = sorted({k.split(".", 2)[1] for k, _ in config if k.startswith("remote.") and k.endswith(".url") and k.count(".") >= 2})
    if pos:
        remote = pos[0]
        if remote not in remotes:
            return None, f"{remote!r} is not a configured remote name in {cwd} (URLs and paths are not accepted)"
    else:
        candidates = [config_get(config, f"branch.{branch}.remote")] if branch else []
        if r.op == "push":
            candidates = ([config_get(config, f"branch.{branch}.pushremote")] if branch else []) + \
                         [config_get(config, "remote.pushdefault")] + candidates
        remote = next((c for c in candidates if c), "origin")
        if remote not in remotes:
            return None, f"no remote given and {remote!r} is not configured in {cwd}"
    urls = [v for k, v in config if k == f"remote.{remote}.url"]
    pushurls = [v for k, v in config if k == f"remote.{remote}.pushurl"]
    for url in urls + pushurls:
        reason = check_remote_url(url)
        if reason:
            return None, reason

    refs = refs_of(lambda *a: agit(cwd, *a))
    snapshot = sorted((k, v) for k, v in refs.items() if k.startswith(("refs/heads/", "refs/tags/")))
    fp = hashlib.sha256(json.dumps([r.op, r.args, str(cwd), str(gitdir), remote, urls, pushurls,
                                    head_ref, head_sha, snapshot]).encode()).hexdigest()
    return Facts(cwd=cwd, gitdir=gitdir, common=common, objects=objects, head_ref=head_ref, head_sha=head_sha, refs=refs,
                 config=config, remote=remote, urls=urls, pushurls=pushurls, fingerprint=fp), ""


def validate(r: Request) -> str:
    """Empty string if the request may be shown to the developer, else the reason."""
    return inspect(r)[1]


# ---------------------------------------------------------------- shadow repository
def build_shadow(f: Facts, tmp: str) -> Path:
    """A bare repository under host control: agent objects via alternates, data config, ref snapshot."""
    shadow = Path(tmp) / "shadow.git"
    fmt = config_get(f.config, "extensions.objectformat")
    p = hgit("-c", "init.defaultBranch=main", "-c", "init.templateDir=", "init", "--bare", "-q",
             *(["--object-format", fmt] if fmt else []), str(shadow), cwd=tmp)
    if p.returncode != 0:
        raise RuntimeError(f"cannot create shadow repository: {p.stderr.strip()}")
    (shadow / "objects" / "info").mkdir(parents=True, exist_ok=True)
    (shadow / "objects" / "info" / "alternates").write_text(str(f.objects) + "\n")
    settings = [("core.hooksPath", "/dev/null"), ("core.fsmonitor", "false"),
                ("transfer.unpackLimit", "1"), ("fetch.writeCommitGraph", "false"), ("gc.auto", "0")]
    for k, v in f.config:
        parts = k.split(".")
        if k in SHADOW_PLAIN_KEYS or SHADOW_BRANCH_KEYS.match(k) or \
                (len(parts) == 3 and parts[0] == "remote" and parts[1] == f.remote and parts[2] in SHADOW_REMOTE_KEYS):
            settings.append((k, v))
    for k, v in settings:
        hgit("config", "--file", str(shadow / "config"), "--add", k, v)
    if f.refs:
        p = sgit(shadow, "update-ref", "--stdin", input="".join(f"create {ref} {sha}\n" for ref, sha in f.refs.items()))
        if p.returncode != 0:
            raise RuntimeError(f"cannot mirror refs into the shadow repository: {p.stderr.strip()}")
    if f.head_ref:
        (shadow / "HEAD").write_text(f"ref: {f.head_ref}\n")
    elif f.head_sha:
        (shadow / "HEAD").write_text(f.head_sha + "\n")
    return shadow


def fetch_args(r: Request) -> list:
    """Arguments for the fetch half; a pull's merge options stay behind."""
    if r.op != "pull":
        return list(r.args)
    return [a for a in r.args if not a.startswith("-") or a.split("=", 1)[0] in PULL_FETCH_OPTS]


def copy_objects(shadow: Path, f: Facts) -> int:
    """Move new pack and loose object files into the agent's object store. Returns the count."""
    n = 0
    src_root = shadow / "objects"
    files = []
    for path in src_root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(src_root)
        if rel.parts[0] == "info":
            continue
        files.append(rel)
    files.sort(key=lambda rel: (rel.suffix == ".idx", str(rel)))    # .idx last: readers use it as the marker
    for rel in files:
        dst = f.objects / rel
        if dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.parent / f".sbx-{dst.name}"
        shutil.copy2(shadow / "objects" / rel, tmp)
        os.replace(tmp, dst)
        n += 1
    return n


def import_fetch(shadow: Path, f: Facts) -> tuple:
    """Bring fetched objects, ref updates and FETCH_HEAD into the agent's repository."""
    after = refs_of(lambda *a: sgit(shadow, *a))
    ops = []
    for ref, sha in after.items():
        old = f.refs.get(ref)
        if old is None:
            ops.append(f"create {ref} {sha}")
        elif old != sha:
            ops.append(f"update {ref} {sha} {old}")
    for ref, old in f.refs.items():
        if ref not in after:
            ops.append(f"delete {ref} {old}")
    n_obj = copy_objects(shadow, f)
    if ops:
        p = agit_dir(f.gitdir, "update-ref", "--stdin", input="".join(o + "\n" for o in ops))
        if p.returncode != 0:
            return 1, f"import failed: refs changed while fetching, nothing updated ({p.stderr.strip()})"
    fetch_head = shadow / "FETCH_HEAD"
    if fetch_head.is_file():
        tmp = f.gitdir / ".sbx-FETCH_HEAD"
        shutil.copyfile(fetch_head, tmp)
        os.replace(tmp, f.gitdir / "FETCH_HEAD")
    return 0, f"imported: {n_obj} object files, {len(ops)} ref updates into {f.gitdir}"


def import_upstream(shadow: Path, f: Facts) -> str:
    """Carry over branch tracking that `push --set-upstream` recorded in the shadow config."""
    before = {k: v for k, v in f.config if SHADOW_BRANCH_KEYS.match(k)}
    changed = []
    for k, v in read_config(shadow / "config"):
        if SHADOW_BRANCH_KEYS.match(k) and before.get(k) != v:
            hgit("config", "--file", str(f.common / "config"), k, v)
            changed.append(k)
    return f"tracking: {', '.join(changed)}" if changed else ""


# ---------------------------------------------------------------- preview and execution
def preview(r: Request, f: Facts) -> str:
    out = [f"$ {r.command}", f"requested {r.time} from branch {r.branch} at {r.head[:12]}", ""]
    for url in f.urls:
        out.append(f"remote {f.remote} -> {url}")
    for url in f.pushurls:
        out.append(f"remote {f.remote} (push) -> {url}")
    out.append("")
    with tempfile.TemporaryDirectory(prefix="sbx-git-") as tmp:
        shadow = build_shadow(f, tmp)
        if r.op == "push":
            _, pos = split_args(r.args)
            specs = pos[1:] or [r.branch if r.branch not in ("", "?", "HEAD") else "HEAD"]
            for spec in specs:
                src, _, dst = spec.partition(":")
                dst = dst or src
                tracking = f"{f.remote}/{dst}"
                if sgit(shadow, "rev-parse", "--verify", "-q", tracking).returncode == 0:
                    log = sgit(shadow, "log", "--oneline", "--no-show-signature", f"{tracking}..{src}").stdout
                    stat = sgit(shadow, "diff", "--stat", "--no-ext-diff", f"{tracking}...{src}").stdout
                    out.append(f"commits {tracking}..{src}:")
                    out.append(log.rstrip() or "  (nothing to push)")
                    out.append("")
                    out.append(stat.rstrip())
                else:
                    log = sgit(shadow, "log", "--oneline", "--no-show-signature", "-n", "20", src).stdout
                    out.append(f"{tracking} does not exist yet: new remote branch. Last commits of {src}:")
                    out.append(log.rstrip())
                out.append("")
        else:
            out.append("fetch on the host: " + " ".join(["git", "fetch"] + fetch_args(r)))
            if f.head_ref.startswith("refs/heads/"):
                branch = f.head_ref[len("refs/heads/"):]
                merge = config_get(f.config, f"branch.{branch}.merge")
                rem = config_get(f.config, f"branch.{branch}.remote")
                if merge.startswith("refs/heads/") and rem:
                    tracking = f"refs/remotes/{rem}/{merge[len('refs/heads/'):]}"
                    p = sgit(shadow, "rev-list", "--left-right", "--count", f"{f.head_ref}...{tracking}")
                    if p.returncode == 0:
                        ahead, behind = p.stdout.split()
                        out.append(f"branch {branch} vs {tracking}: ahead {ahead}, behind {behind} (before this fetch)")
            if r.op == "pull":
                out.append("the merge or rebase half runs inside the container on the agent's next `git pull`")
    return "\n".join(out).rstrip() + "\n"


def _move(r: Request, sub: str, result: str) -> None:
    target = r.reqdir / sub
    target.mkdir(parents=True, exist_ok=True)
    (target / f"{r.id}.result").write_text(result, encoding="utf-8")
    if r.path.exists():
        shutil.move(str(r.path), str(target / r.path.name))


def reject(r: Request, reason: str) -> None:
    _move(r, "rejected", f"rejected: {reason}\ntime: {now()}\ncommand: {r.command}\n")


def execute(r: Request, f: Facts) -> tuple:
    """Run the approved operation in a shadow repository; import results. Returns (rc, output)."""
    notes = []
    try:
        with tempfile.TemporaryDirectory(prefix="sbx-git-") as tmp:
            shadow = build_shadow(f, tmp)
            op = "push" if r.op == "push" else "fetch"
            args = r.args if op == "push" else fetch_args(r)
            notes.append("executed: git --git-dir=<shadow> " + " ".join([op] + args))
            p = sgit(shadow, op, *args, timeout=600)
            rc, output = p.returncode, (p.stdout + p.stderr)
            if rc == 0 and op == "fetch":
                rc, note = import_fetch(shadow, f)
                notes.append(note)
                if rc == 0 and r.op == "pull":
                    (r.reqdir / "done").mkdir(parents=True, exist_ok=True)
                    (r.reqdir / "done" / f"{r.id}.merge").write_text(f"cwd: {r.cwd}\nrequest: {r.id}\n")
                    notes.append("merge: pending in the container; run the same `git pull` again there")
            elif rc == 0:
                note = import_upstream(shadow, f)
                if note:
                    notes.append(note)
    except subprocess.TimeoutExpired:
        rc, output = 124, "timed out after 600 s\n"
    except RuntimeError as e:
        rc, output = 1, str(e) + "\n"
    if notes:
        output = output.rstrip("\n") + "\n" + "\n".join(notes) + "\n"
    _move(r, "done", f"exit: {rc}\ntime: {now()}\ncommand: {r.command}\n\n{output}")
    return rc, output


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def pending(project: Path, reqdir: Path = None) -> list:
    reqdir = reqdir or requests_dir(project)
    if not reqdir.is_dir():
        return []
    return [parse_request(p, reqdir, project) for p in sorted(reqdir.glob("*.req"))]


def all_projects() -> list:
    """(project, reqdir) for every request dir that knows its project."""
    out = []
    base = STATE / "projects"
    if not base.is_dir():
        return out
    for d in sorted(base.iterdir()):
        reqdir = d / "requests"
        pf = d / "project"          # outside the mounted requests/ dir: not writable by the agent
        if pf.is_file():
            out.append((Path(pf.read_text().strip()), reqdir))
    return out


def find_request(rid: str):
    """Locate a request id: returns (state, Request or result text)."""
    if "/" in rid or ".." in rid:
        return None, None
    for project, reqdir in all_projects():
        p = reqdir / f"{rid}.req"
        if p.is_file():
            return "pending", parse_request(p, reqdir, project)
        for sub in ("done", "rejected"):
            res = reqdir / sub / f"{rid}.result"
            if res.is_file():
                return sub, res.read_text(errors="replace")
    return None, None


# ---------------------------------------------------------------- terminal
def run_terminal(project: Path) -> int:
    project = project.resolve()
    reqdir = requests_dir(project)
    reqdir.mkdir(parents=True, exist_ok=True)
    (reqdir.parent / "project").write_text(str(project) + "\n")
    reqs = pending(project, reqdir)
    if not reqs:
        print(f"sbx-git: no pending requests for {project}")
        return 0
    for r in reqs:
        print("=" * 72)
        print(f"request {r.id}")
        facts, reason = inspect(r)
        if reason:
            reject(r, reason)
            print(f"REJECTED automatically: {reason}")
            continue
        try:
            print(preview(r, facts))
        except RuntimeError as e:
            reject(r, str(e))
            print(f"REJECTED automatically: {e}")
            continue
        try:
            answer = input("[y]es run it / [n]o reject / [s]kip: ").strip().lower()
        except EOFError:
            answer = "s"
        if answer in ("y", "yes", "j", "ja"):
            rc, output = execute(r, facts)
            print(output.rstrip())
            print(f"exit {rc}, result in {r.reqdir / 'done' / (r.id + '.result')}")
        elif answer in ("n", "no", "nein"):
            reject(r, "declined by developer")
            print("declined")
        else:
            print("skipped")
    return 0


# ---------------------------------------------------------------- web
PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>sbx-git</title>{refresh}
<style>
body{{font:15px/1.5 system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem;color:#1c222a;background:#f4f5f2}}
pre{{background:#fff;border:1px solid #d3d8d4;padding:1rem;overflow-x:auto;white-space:pre-wrap}}
.warn{{color:#8b2e2a;font-weight:600}} .muted{{color:#566069}}
form{{display:inline-block;margin-right:1rem}} button{{font:inherit;padding:.4rem 1rem}}
table{{border-collapse:collapse}} td,th{{text-align:left;padding:.3rem .8rem;border-bottom:1px solid #d3d8d4}}
</style></head><body><h1><a href="/" style="color:inherit;text-decoration:none">sbx-git</a></h1>{body}</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    token = ""
    port = DEFAULT_PORT
    server_version = "sbx-git"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (now(), fmt % args))

    def send_page(self, body: str, status: int = 200, refresh: bool = False):
        data = PAGE.format(body=body, refresh='<meta http-equiv="refresh" content="10">' if refresh else "").encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def loopback_ok(self) -> bool:
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            return False
        origin = self.headers.get("Origin")
        if origin:
            o = urllib.parse.urlparse(origin)
            if o.hostname not in ("127.0.0.1", "localhost") or (o.port or 80) != self.port:
                return False
        return True

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            return self.page_index()
        if path.startswith("/r/"):
            parts = path[3:].split("/")
            if len(parts) == 1:
                return self.page_request(parts[0])
            self.send_page("<p>Approve and reject accept POST only.</p>", 405)
            return
        self.send_page("<p>Not found.</p>", 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        parts = path[3:].split("/") if path.startswith("/r/") else []
        if len(parts) != 2 or parts[1] not in ("approve", "reject"):
            return self.send_page("<p>Not found.</p>", 404)
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(length).decode(errors="replace"))
        token = (form.get("token") or [""])[0]
        if not self.loopback_ok() or not secrets.compare_digest(token, self.token):
            return self.send_page("<p class=warn>Refused: invalid token or origin.</p>", 403)
        state, r = find_request(parts[0])
        if state != "pending":
            return self.send_page("<p>Request is no longer pending.</p>", 409)
        facts, reason = inspect(r)
        if reason:
            reject(r, reason)
            return self.send_page(f"<p class=warn>Rejected automatically: {html.escape(reason)}</p>")
        if parts[1] == "reject":
            reject(r, "declined by developer")
            return self.send_page(f"<p>Request {html.escape(r.id)} declined.</p><p><a href='/'>back</a></p>")
        fp = (form.get("fp") or [""])[0]
        if not secrets.compare_digest(fp, facts.fingerprint):
            return self.send_page(f"<h2>Request {html.escape(r.id)}</h2><p class=warn>Not run: the repository changed after "
                                  f"the preview (remote URL, refs or arguments). Review it again.</p>"
                                  f"<p><a href='/r/{html.escape(r.id)}'>show current state</a></p>", 409)
        rc, output = execute(r, facts)
        cls = "" if rc == 0 else " class=warn"
        self.send_page(f"<h2>Request {html.escape(r.id)}</h2><p{cls}>git {html.escape(r.op)} exited with {rc}</p>"
                       f"<pre>{html.escape(output)}</pre><p><a href='/'>back</a></p>")

    def page_index(self):
        rows, rejected_rows = [], []
        for project, reqdir in all_projects():
            for r in pending(project, reqdir):
                reason = validate(r)
                if reason:
                    reject(r, reason)
                    rejected_rows.append(f"<tr><td>{html.escape(r.id)}</td><td>{html.escape(str(project))}</td>"
                                         f"<td class=warn>{html.escape(reason)}</td></tr>")
                    continue
                rows.append(f"<tr><td><a href='/r/{html.escape(r.id)}'>{html.escape(r.id)}</a></td>"
                            f"<td>{html.escape(str(project))}</td><td><code>git {html.escape(' '.join([r.op] + r.args))}</code></td>"
                            f"<td class=muted>{html.escape(r.time)}</td></tr>")
        body = "<h2>Pending requests</h2>"
        body += ("<table><tr><th>id</th><th>project</th><th>command</th><th>time</th></tr>" + "".join(rows) + "</table>"
                 if rows else "<p class=muted>None. This page refreshes every 10 seconds.</p>")
        if rejected_rows:
            body += "<h2>Rejected automatically</h2><table><tr><th>id</th><th>project</th><th>reason</th></tr>" + "".join(rejected_rows) + "</table>"
        self.send_page(body, refresh=True)

    def page_request(self, rid: str):
        state, r = find_request(rid)
        if state is None:
            return self.send_page(f"<p>No request {html.escape(rid)}.</p>", 404)
        if state != "pending":
            return self.send_page(f"<h2>Request {html.escape(rid)}: {state}</h2><pre>{html.escape(r)}</pre><p><a href='/'>back</a></p>")
        facts, reason = inspect(r)
        if not reason:
            try:
                text = preview(r, facts)
            except RuntimeError as e:
                reason = str(e)
        if reason:
            reject(r, reason)
            return self.send_page(f"<h2>Request {html.escape(rid)}</h2><p class=warn>Rejected automatically: {html.escape(reason)}</p>")
        hidden = f"<input type=hidden name=\"token\" value=\"{self.token}\"><input type=hidden name=\"fp\" value=\"{facts.fingerprint}\">"
        body = (f"<h2>Request {html.escape(rid)}</h2><p class=muted>project {html.escape(str(r.project))}</p>"
                f"<pre>{html.escape(text)}</pre>"
                f"<form method=post action='/r/{html.escape(rid)}/approve'>{hidden}"
                f"<button type=submit>Run on host: git {html.escape(r.op)}</button></form>"
                f"<form method=post action='/r/{html.escape(rid)}/reject'>{hidden}"
                f"<button type=submit>Reject</button></form>")
        self.send_page(body)


def serve(port: int) -> int:
    Handler.token = secrets.token_hex(16)
    Handler.port = port
    try:
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        print(f"sbx-git: cannot bind 127.0.0.1:{port}: {e}", file=sys.stderr)
        return 1
    print(f"sbx-git: serving http://127.0.0.1:{port}/ (loopback only)", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", help="project directory (terminal mode)")
    ap.add_argument("--serve", action="store_true", help="run the web UI")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    a = ap.parse_args(argv)
    if a.serve:
        return serve(a.port)
    return run_terminal(Path(a.project or os.getcwd()))


if __name__ == "__main__":
    sys.exit(main())
