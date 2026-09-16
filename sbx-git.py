#!/usr/bin/env python3
"""sbx-git: review and run git remote operations requested from inside the sandbox.

    sbx-git.py --project DIR         terminal review of that project's pending requests
    sbx-git.py --serve [--port N]    web UI on http://127.0.0.1:N (default 7331), all projects

Requests are files written by the container's git wrapper into
~/.local/state/sbx/projects/<p>/requests/. They are untrusted data: every
request is validated here before anything runs, and only git remote *names*
configured in the repository are accepted as targets. Approved operations run
on the host with the host's credentials; outcomes are written to done/ or
rejected/ next to the request so the agent can read them.
"""
import argparse
import html
import http.server
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

OPS = ("push", "fetch", "pull")
DEFAULT_PORT = 7331
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "sbx"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "sbx"
KNOWN_HOSTS = ("github.com",)
# push options that rewrite or delete remote history
FORBIDDEN_PUSH = ("--force", "-f", "--force-with-lease", "--force-if-includes",
                  "--delete", "-d", "--mirror", "--prune", "--all")
# options that make git run a program on the host
FORBIDDEN_EXEC_PREFIXES = ("--receive-pack", "--exec", "--upload-pack", "-u", "--config")


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


def git(cwd: str, *args: str, timeout: int = 60) -> subprocess.CompletedProcess:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_PAGER="cat", PAGER="cat")
    return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True,
                          env=env, timeout=timeout)


def split_args(args: list):
    """Return (options, positionals) for the recorded subcommand arguments."""
    opts, pos = [], []
    for a in args:
        (opts if a.startswith("-") else pos).append(a)
    return opts, pos


def validate(r: Request) -> str:
    """Return an empty string if the request may be shown to the developer, else the reason."""
    if r.error:
        return r.error
    if r.op not in OPS:
        return f"operation {r.op!r} is not one of {', '.join(OPS)}"
    try:
        cwd = Path(r.cwd).resolve(strict=True)
    except OSError:
        return f"working directory {r.cwd} does not exist on the host"
    roots = allowed_roots(r.project)
    if not any(cwd == root or root in cwd.parents for root in roots):
        return f"working directory {cwd} lies outside the project and its extra mounts"
    p = git(str(cwd), "rev-parse", "--is-inside-work-tree")
    if p.returncode != 0 or p.stdout.strip() != "true":
        return f"{cwd} is not a git work tree"
    opts, pos = split_args(r.args)
    for o in opts:
        name = o.split("=", 1)[0]
        if name.startswith(FORBIDDEN_EXEC_PREFIXES):
            return f"option {o} would run a program on the host"
        if r.op == "push":
            if name in FORBIDDEN_PUSH or name.startswith("--force"):
                return f"push option {o} rewrites or deletes remote history"
            if not o.startswith("--") and any(c in o[1:] for c in "fd"):
                return f"push option {o} combines -f or -d"
    if r.op == "push":
        for spec in pos[1:]:
            if spec.startswith("+"):
                return f"refspec {spec} forces the update"
            if spec.startswith(":"):
                return f"refspec {spec} deletes a remote branch"
    remotes = git(str(cwd), "remote").stdout.split()
    if pos:
        if pos[0] not in remotes:
            return f"{pos[0]!r} is not a configured remote name in {cwd} (URLs and paths are not accepted)"
    return ""


def remote_for(r: Request) -> str:
    _, pos = split_args(r.args)
    if pos:
        return pos[0]
    p = git(r.cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if p.returncode == 0 and "/" in p.stdout:
        return p.stdout.strip().split("/", 1)[0]
    return "origin"


def preview(r: Request) -> str:
    out = [f"$ {r.command}", f"requested {r.time} from branch {r.branch} at {r.head[:12]}", ""]
    remote = remote_for(r)
    url = git(r.cwd, "remote", "get-url", remote).stdout.strip() or "(no URL)"
    out.append(f"remote {remote} -> {url}")
    host = urllib.parse.urlparse(url if "://" in url else "ssh://" + url.replace(":", "/", 1)).hostname or ""
    if "://" in url or "@" in url:
        if not any(host == k or host.endswith("." + k) for k in KNOWN_HOSTS):
            out.append(f"WARNING: remote host {host!r} is not one of {', '.join(KNOWN_HOSTS)}")
    out.append("")
    if r.op == "push":
        _, pos = split_args(r.args)
        specs = pos[1:] or [r.branch if r.branch not in ("", "?", "HEAD") else "HEAD"]
        for spec in specs:
            src, _, dst = spec.partition(":")
            dst = dst or src
            tracking = f"{remote}/{dst}"
            if git(r.cwd, "rev-parse", "--verify", "-q", tracking).returncode == 0:
                log = git(r.cwd, "log", "--oneline", f"{tracking}..{src}").stdout
                stat = git(r.cwd, "diff", "--stat", f"{tracking}...{src}").stdout
                out.append(f"commits {tracking}..{src}:")
                out.append(log.rstrip() or "  (nothing to push)")
                out.append("")
                out.append(stat.rstrip())
            else:
                log = git(r.cwd, "log", "--oneline", "-n", "20", src).stdout
                out.append(f"{tracking} does not exist yet: new remote branch. Last commits of {src}:")
                out.append(log.rstrip())
            out.append("")
    else:
        out.append(git(r.cwd, "status", "-sb").stdout.rstrip())
    return "\n".join(out).rstrip() + "\n"


def _move(r: Request, sub: str, result: str) -> None:
    target = r.reqdir / sub
    target.mkdir(parents=True, exist_ok=True)
    (target / f"{r.id}.result").write_text(result, encoding="utf-8")
    if r.path.exists():
        shutil.move(str(r.path), str(target / r.path.name))


def reject(r: Request, reason: str) -> None:
    _move(r, "rejected", f"rejected: {reason}\ntime: {now()}\ncommand: {r.command}\n")


def execute(r: Request) -> tuple:
    try:
        p = git(r.cwd, r.op, *r.args, timeout=600)
        rc, output = p.returncode, (p.stdout + p.stderr)
    except subprocess.TimeoutExpired:
        rc, output = 124, "timed out after 600 s\n"
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
        reason = validate(r)
        if reason:
            reject(r, reason)
            print(f"REJECTED automatically: {reason}")
            continue
        print(preview(r))
        try:
            answer = input("[y]es run it / [n]o reject / [s]kip: ").strip().lower()
        except EOFError:
            answer = "s"
        if answer in ("y", "yes", "j", "ja"):
            rc, output = execute(r)
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
        reason = validate(r)
        if reason:
            reject(r, reason)
            return self.send_page(f"<p class=warn>Rejected automatically: {html.escape(reason)}</p>")
        if parts[1] == "reject":
            reject(r, "declined by developer")
            return self.send_page(f"<p>Request {html.escape(r.id)} declined.</p><p><a href='/'>back</a></p>")
        rc, output = execute(r)
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
        reason = validate(r)
        if reason:
            reject(r, reason)
            return self.send_page(f"<h2>Request {html.escape(rid)}</h2><p class=warn>Rejected automatically: {html.escape(reason)}</p>")
        text = html.escape(preview(r)).replace("WARNING:", "<span class=warn>WARNING:</span>")
        body = (f"<h2>Request {html.escape(rid)}</h2><p class=muted>project {html.escape(str(r.project))}</p>"
                f"<pre>{text}</pre>"
                f"<form method=post action='/r/{html.escape(rid)}/approve'><input type=hidden name=\"token\" value=\"{self.token}\">"
                f"<button type=submit>Run on host: git {html.escape(r.op)}</button></form>"
                f"<form method=post action='/r/{html.escape(rid)}/reject'><input type=hidden name=\"token\" value=\"{self.token}\">"
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
