#!/usr/bin/env python3
"""Plan/apply releases from Conventional Commits, preserving reviewed JSON notes.

Only GitHub Actions invokes `apply` automatically. `next` never writes files.
The release workflow builds the exact committed revision and uploads a draft
before making binaries visible. Source tags stay in the private repository.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SEMVER = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
VERSION_RE = re.compile(rf"^version:\s*({SEMVER})\+([1-9]\d*)\s*$", re.M)
COMMIT_RE = re.compile(r"^([a-z]+)(?:\([^)]*\))?(!)?:\s*(.+)$", re.I)
MAX_BUILD = (2_100_000_000 - 100_000 - 4) // 10


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True,
                          capture_output=True, text=True, encoding="utf-8").stdout.strip()


def get_remote_public_tags(slug: str) -> set[str]:
    try:
        url = f"https://github.com/Auralix-Studio/{slug}.git"
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
        res = subprocess.run(
            ["git", "-c", "core.askPass=", "ls-remote", "--tags", url],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            timeout=5,
        )
        if res.returncode != 0:
            return set()
        tags = set()
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 2 and parts[1].startswith("refs/tags/"):
                tag = parts[1][len("refs/tags/"):]
                if tag.endswith("^{}"):
                    tag = tag[:-3]
                if re.fullmatch(r"v" + SEMVER, tag):
                    tags.add(tag)
        return tags
    except Exception:
        return set()


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(map(int, value.split(".")))


def bump(value: str, kind: str) -> str:
    major, minor, patch = version_tuple(value)
    if kind == "major":
        return f"{major + 1}.0.0"
    if kind == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def classify(subject: str, body: str = "") -> tuple[int, str, str]:
    match = COMMIT_RE.fullmatch(subject)
    kind, bang, description = match.groups() if match else ("", "", subject)
    kind = kind.lower()
    if subject.startswith(("chore(release):", "Merge ")):
        return 0, "improvement", description
    breaking = bool(bang) or bool(re.search(r"^BREAKING[ -]CHANGE:", body, re.M))
    level = 3 if breaking else 2 if kind == "feat" else 0 if kind in {
        "docs", "ci", "test", "tests", "style"
    } else 1
    return level, "feature" if kind == "feat" else "fix" if kind == "fix" else "improvement", description


def plan(forced: str = "auto") -> dict:
    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8-sig")
    matches = list(VERSION_RE.finditer(pubspec))
    if len(matches) != 1:
        raise ValueError("pubspec.yaml requires exactly one version: X.Y.Z+N")
    current, raw_build = matches[0].groups()
    tags = [tag for tag in git("tag", "--list", "v*", "--merged", "HEAD").splitlines()
            if re.fullmatch("v" + SEMVER, tag)]
    latest = max(tags, key=lambda tag: version_tuple(tag[1:])) if tags else None
    commits = git("log", f"{latest}..HEAD" if latest else "HEAD", "--no-merges",
                  "--format=%s%x1f%b%x1e")
    changes = []
    level = 0
    for chunk in commits.split("\x1e"):
        if not chunk.strip():
            continue
        subject, _, body = chunk.strip().partition("\x1f")
        rank, kind, description = classify(subject.strip(), body)
        level = max(level, rank)
        entry = {"type": kind, "description": description}
        if rank and entry not in changes:
            changes.append(entry)
    if forced != "auto":
        level = {"patch": 1, "minor": 2, "major": 3}[forced]
    if not level:
        return {"release": False}
    # Respect a version prepared manually; never move backwards relative to
    # either the current pubspec or already published private source tags.
    candidate = bump(latest[1:], {1: "patch", 2: "minor", 3: "major"}[level]) if latest else current
    candidate = max((candidate, current), key=version_tuple)
    slug_match = re.search(r"^name:\s*([a-z_]+)\s*$", pubspec, re.M)
    slug = slug_match[1] if slug_match else "flux"
    remote_tags = get_remote_public_tags(slug)
    existing = set(git("tag", "--list", "v*").splitlines()) | remote_tags
    if remote_tags:
        highest_remote = max(remote_tags, key=lambda tag: version_tuple(tag[1:]))
        if version_tuple(candidate) <= version_tuple(highest_remote[1:]):
            candidate = bump(highest_remote[1:], {1: "patch", 2: "minor", 3: "major"}[level])
    while f"v{candidate}" in existing:
        candidate = bump(candidate, "patch")
    build = int(raw_build) + 1
    if latest:
        previous = git("show", f"{latest}:pubspec.yaml")
        previous_match = VERSION_RE.search(previous)
        if not previous_match:
            raise ValueError("Latest source tag has no valid build number")
        build = max(build, int(previous_match[2]) + 1)
    if build > MAX_BUILD:
        raise ValueError("Build exceeds the Android versionCode limit")
    return {"release": True, "version": candidate, "build": build,
            "tag": f"v{candidate}", "changes": changes}


def apply(result: dict, date: str) -> None:
    datetime.date.fromisoformat(date)
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Commit local changes before applying an automatic version")
    version, build = result["version"], result["build"]
    pubspec_path = ROOT / "pubspec.yaml"
    notes_path = ROOT / "assets/changelog.json"
    pubspec = pubspec_path.read_text(encoding="utf-8-sig")
    slug_match = re.search(r"^name:\s*([a-z_]+)\s*$", pubspec, re.M)
    if not slug_match or slug_match[1] not in {"flux", "mediakeep"}:
        raise ValueError("Unsupported application")
    name = {"flux": "Flux", "mediakeep": "MediaKeep"}[slug_match[1]]
    entries = json.loads(notes_path.read_text(encoding="utf-8-sig"))
    if not isinstance(entries, list):
        raise ValueError("Changelog must be a JSON array")
    matching = [entry for entry in entries if entry.get("version") == version]
    if len(matching) > 1:
        raise ValueError("Duplicate changelog version")
    # Reviewed entries survive. Pending boilerplate is replaced with actual
    # commit descriptions; release validation remains the final authority.
    entry = matching[0] if matching else {"version": version, "date": date,
                                          "title": f"{name} {version}", "changes": []}
    reviewed = [change for change in entry.get("changes", [])
                if not str(change.get("description", "")).startswith("PENDIENTE:")]
    entry["changes"] = reviewed or result["changes"]
    if not entry["changes"]:
        raise ValueError("No release notes: add reviewed changes before forcing a version")
    entry["date"] = date
    entries = [entry] + [old for old in entries if old.get("version") != version]
    full = f"{version}+{build}"
    config = ("// Generated by scripts/sync_version.ps1 from pubspec.yaml. Do not edit.\n"
              "class AppVersion {\n"
              f"  static const String name = '{version}';\n"
              f"  static const int build = {build};\n"
              f"  static const String full = '{full}';\n"
              "}\n")
    pubspec_path.write_text(VERSION_RE.sub(f"version: {full}\n", pubspec, count=1), encoding="utf-8")
    notes_path.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (ROOT / "lib/core/app_version.dart").write_text(config, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("next", "apply"))
    parser.add_argument("--bump", choices=("auto", "patch", "minor", "major"), default="auto")
    parser.add_argument("--date", default=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-5))).date().isoformat())
    args = parser.parse_args()
    result = plan(args.bump)
    if args.command == "apply" and result["release"]:
        apply(result, args.date)
    for key in ("release", "version", "build", "tag"):
        if key in result:
            value = str(result[key]).lower() if isinstance(result[key], bool) else result[key]
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
