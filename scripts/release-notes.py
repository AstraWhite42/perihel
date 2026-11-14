"""Generate Markdown release notes from the published tags supplied on stdin."""
import os
import re
import subprocess
import sys
from urllib.parse import quote


def git(*args):
    return subprocess.check_output(["git", *args], text=True).splitlines()


tag = sys.argv[1]
published = set(sys.stdin.read().splitlines())
previous = next((name for name in git("tag", "--merged", tag, "--sort=-version:refname",
                                     "--list", "v*-build*") if name != tag and name in published), None)
revision = f"{previous}..{tag}" if previous else tag
groups = {"新增": [], "修复": [], "其他更新": []}
for commit, subject in (line.split("\t", 1) for line in git(
        "log", "--reverse", "--no-merges", "--format=%H%x09%s", revision)):
    if git("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit) == ["version.json"]:
        continue
    match = re.fullmatch(r"(\w+)(?:\(([^)]+)\))?!?:\s*(.+)", subject)
    kind, scope, title = match.groups() if match else ("", None, subject)
    groups[{"feat": "新增", "fix": "修复"}.get(kind, "其他更新")].append(
        f"{scope}：{title}" if scope else title)

for heading, titles in groups.items():
    if titles:
        print(f"## {heading}\n")
        for title in titles:
            print(f"- {title}")
        print()

repo = f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
if previous:
    print(f"[完整差异]({repo}/compare/{quote(previous)}...{quote(tag)})")
else:
    print(f"[完整提交记录]({repo}/commits/{quote(tag)})")
