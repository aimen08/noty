#!/bin/bash
# Writes the notes for one release, from the pull requests it actually contains.
#
#   VERSION=1.2.0 ./scripts/make-release-notes.sh [previous-tag]
#
# Leaves build/release-notes.md (for the GitHub release page) and
# build/release-notes.html (for the Sparkle appcast, which takes HTML) behind,
# and prints the markdown.
#
# A pull request belongs to a release when its merge commit is reachable from
# HEAD but not from the previous tag. Filtering by merge *date* instead looks
# equivalent and is not: work merged into dev sits unreleased until dev lands on
# main, so a date window hands it to whatever release comes next — including a
# hotfix straight to main that does not contain it — and the release that really
# ships it lists nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:?set VERSION}"
REPO="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null \
        | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"

PREV="${1:-}"
if [ -z "$PREV" ]; then
    # The newest release tag that is an ancestor of HEAD, ignoring the tag for
    # the version being cut in case it already exists.
    PREV="$(git tag --list 'v*' --sort=-v:refname --merged HEAD \
            | grep -vx "v${VERSION}" | head -1 || true)"
fi

RANGE="${PREV:+${PREV}..}HEAD"
mkdir -p build

git rev-list "$RANGE" > build/.release-commits

VERSION="$VERSION" REPO="$REPO" PREV="$PREV" python3 - <<'PY'
import html, json, os, re, subprocess, pathlib

version = os.environ["VERSION"]
repo    = os.environ["REPO"]
prev    = os.environ["PREV"]
commits = set(pathlib.Path("build/.release-commits").read_text().split())

def merged_pulls():
    """Every merged pull request whose merge commit is in this release."""
    try:
        raw = subprocess.run(
            ["gh", "api", "--paginate",
             f"repos/{repo}/pulls?state=closed&per_page=100&sort=updated&direction=desc"],
            capture_output=True, text=True, timeout=90, check=True).stdout
    except Exception as exc:                      # no gh, no network, no token
        print(f"note: could not reach the pull request API ({exc})", flush=True)
        return None
    # --paginate concatenates one JSON array per page.
    pulls, decoder, idx = [], json.JSONDecoder(), 0
    while idx < len(raw):
        while idx < len(raw) and raw[idx].isspace():
            idx += 1
        if idx >= len(raw):
            break
        page, idx = decoder.raw_decode(raw, idx)
        pulls.extend(page)
    seen, out = set(), []
    for p in pulls:
        sha = p.get("merge_commit_sha")
        if not p.get("merged_at") or sha not in commits or p["number"] in seen:
            continue
        seen.add(p["number"])
        out.append(p)
    out.sort(key=lambda p: p["number"])
    return out

def credited():
    """People whose work shipped without a pull request of their own being
    merged — a cherry-pick, or a branch only part of which was taken. Recorded
    as a `Thanks-to: @handle — what for` trailer on the commit that took it, so
    the credit lives with the change instead of in a file someone has to
    remember to clear. `Co-Authored-By:` is picked up as well."""
    rng = [f"{prev}..HEAD"] if prev else ["HEAD"]
    log = subprocess.run(["git", "log", *rng, "--pretty=%B%x00"],
                         capture_output=True, text=True).stdout
    out, seen = [], set()
    for message in log.split("\0"):
        for line in message.splitlines():
            line = line.strip()
            m = re.match(r"(?i)^thanks-to:\s*@?([A-Za-z0-9][A-Za-z0-9-]*)"
                         r"\s*(?:[\u2014:-]\s*(.*))?$", line)
            if m:
                handle, why = m.group(1), (m.group(2) or "").strip()
            else:
                m = re.match(r"(?i)^co-authored-by:\s*.+?\s*<(.+?)>$", line)
                if not m:
                    continue
                # Only a co-author who resolves to a real GitHub account. Tool
                # and bot trailers use their own domains and have no profile to
                # link to; release notes are for the people who wrote the code.
                gh = re.match(r"^\d+\+([A-Za-z0-9-]+)@users\.noreply\.github\.com$",
                              m.group(1))
                if not gh:
                    continue
                handle, why = gh.group(1), ""
            if handle.lower() in seen:
                continue
            seen.add(handle.lower())
            out.append((handle, why))
    return out

def closed_issues():
    """Issues this release answers, from `Closes #N` / `Fixes #N` /
    `Implements #N` in its commit messages — so work that lands as a direct
    commit still credits the person who asked for it."""
    rng = [f"{prev}..HEAD"] if prev else ["HEAD"]
    log = subprocess.run(["git", "log", *rng, "--pretty=%B"],
                         capture_output=True, text=True).stdout
    numbers = []
    for m in re.finditer(r"(?i)\b(?:closes|fixes|resolves|implements)\s+#(\d+)", log):
        n = int(m.group(1))
        if n not in numbers:
            numbers.append(n)
    out = []
    for n in sorted(numbers):
        try:
            raw = subprocess.run(
                ["gh", "api", f"repos/{repo}/issues/{n}",
                 "--jq", "[.title, .user.login, .html_url, (.pull_request != null)] | @tsv"],
                capture_output=True, text=True, timeout=30, check=True).stdout.strip()
            title, who, url, is_pr = raw.split("\t")
            if is_pr == "true":      # PR references are already listed above
                continue
            out.append((n, title, who, url))
        except Exception:
            out.append((n, None, None, f"https://github.com/{repo}/issues/{n}"))
    return out

pulls = merged_pulls()
thanks = credited()
issues = closed_issues()

md, items = [], []
if pulls:
    md.append("## Merged pull requests\n")
    for p in pulls:
        who = p["user"]["login"]
        md.append(f"- [#{p['number']}]({p['html_url']}) {p['title']} — "
                  f"[@{who}](https://github.com/{who})")
        items.append((p["number"], p["html_url"], p["title"], who))
    md.append("")
else:
    # A hotfix straight to main, or the API was unreachable. The commit subjects
    # are always available and are better than an empty release page.
    subjects = [s for s in subprocess.run(
        ["git", "log", "--no-merges", "--pretty=%s"] +
        ([f"{prev}..HEAD"] if prev else ["HEAD"]),
        capture_output=True, text=True).stdout.splitlines() if s.strip()]
    if subjects:
        md.append("## Changes\n")
        for s in subjects[:40]:
            md.append(f"- {s}")
            items.append((None, None, s, None))
        md.append("")

if issues:
    md.append("## Answered issues\n")
    for n, title, who, url in issues:
        if title:
            md.append(f"- [#{n}]({url}) {title} — requested by "
                      f"[@{who}](https://github.com/{who})")
        else:
            md.append(f"- [#{n}]({url})")
    md.append("")

if thanks:
    md.append("## Thanks\n")
    for handle, why in thanks:
        link = f"[@{handle}](https://github.com/{handle})"
        md.append(f"- {link}{' — ' + why if why else ''}")
    md.append("")

if prev:
    compare = f"https://github.com/{repo}/compare/{prev}...v{version}"
    md.append(f"**Full changelog**: [{prev}...v{version}]({compare})")

markdown = "\n".join(md).strip() + "\n"
pathlib.Path("build/release-notes.md").write_text(markdown)

# Sparkle renders the appcast description as HTML, not markdown.
rows = []
for number, url, title, who in items:
    title = html.escape(title)
    if number is None:
        rows.append(f"<li>{title}</li>")
    else:
        rows.append(f'<li><a href="{html.escape(url)}">#{number}</a> {title} '
                    f'&mdash; @{html.escape(who)}</li>')
body = f"<p>Noty {html.escape(version)}</p>"
if rows:
    body += "<ul>" + "".join(rows) + "</ul>"
if issues:
    rows = "".join(
        f'<li><a href="{html.escape(u)}">#{n}</a> {html.escape(t)} &mdash; requested by @{html.escape(w)}</li>'
        for n, t, w, u in issues if t)
    if rows:
        body += "<p>Answered issues:</p><ul>" + rows + "</ul>"
if thanks:
    names = ", ".join(f"@{html.escape(h)}" for h, _ in thanks)
    body += f"<p>Thanks to {names}.</p>"
pathlib.Path("build/release-notes.html").write_text(body)

print(markdown)
PY

rm -f build/.release-commits
echo "✓ build/release-notes.md and build/release-notes.html → ${VERSION}" >&2
