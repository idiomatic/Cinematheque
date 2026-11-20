#!/usr/bin/env python3
"""Code debt, by the measures DEVELOPMENT.md's Practice keeps: declarations
nothing uses, files past a length, and the spec's length. Prints what it
finds; exits 1 if a declaration is unused, so a check can stop on it."""

import collections
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
# A file this long is due a split.
LONG = 1600
# Names a framework calls, not the code.
CALLED = {
    "_", "body", "main", "test", "makeBody", "makeNSView", "updateNSView",
    "makeCoordinator", "animatableData", "effectValue", "callAsFunction",
    "acceptsFirstResponder", "playerViewControllerShouldDismiss", "std_options",
    "format", "CinemathequeApp", "makeUIView", "updateUIView",
    "textFieldShouldReturn", "textFieldDidEndEditing",
}

files = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "core/src", "cli/src", "apple/Cinematheque"],
                       cwd=root, capture_output=True, text=True, check=True).stdout.split()
code = [f for f in files if f.endswith((".zig", ".swift", ".js"))]
texts = {f: (root / f).read_text() for f in code}
everything = "\n".join(texts.values()) + (root / "core/include/cinematheque.h").read_text()
words = collections.Counter(re.findall(r"[A-Za-z_]\w*", everything))

unused = []
for f, text in texts.items():
    for m in re.finditer(r"\b(?:func|var|let|struct|class|enum|fn|const|function)\s+([A-Za-z_]\w*)", text):
        name = m.group(1)
        if words[name] <= 1 and name not in CALLED:
            unused.append(f"{f}:{text.count(chr(10), 0, m.start()) + 1}: {name}")

long = sorted(((t.count("\n"), f) for f, t in texts.items() if t.count("\n") > LONG), reverse=True)
total = sum(t.count("\n") for t in texts.values())
spec = len((root / "AGENTS.md").read_text().split())

print(f"code: {total:,} lines in {len(code)} files; spec: {spec:,} words")
for n, f in long:
    print(f"long: {f}: {n:,} lines (over {LONG})")
for u in unused:
    print(f"unused: {u}")
sys.exit(1 if unused else 0)
