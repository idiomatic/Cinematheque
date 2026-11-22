#!/bin/sh
# Prints a version's section of the changelog, without its heading or the
# blank lines around it, for a release's notes:
#   tools/release-notes.sh VERSION [CHANGELOG]
# CHANGELOG defaults to the repository's CHANGELOG.md. Fails if it has no
# `## VERSION` heading, or the section is empty.
set -eu
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 VERSION [CHANGELOG]" >&2
    exit 2
fi
version=$1
changelog=${2:-$(dirname "$0")/../CHANGELOG.md}
awk -v heading="## $version" '
    $0 == heading { found = 1; inside = 1; next }
    inside && /^## / { inside = 0 }
    inside {
        if ($0 ~ /^[[:space:]]*$/) { blanks++; next }
        if (printed) for (; blanks > 0; blanks--) print ""
        blanks = 0
        print
        printed = 1
    }
    END {
        if (!found) { print "error: no section \"" heading "\"" > "/dev/stderr"; exit 1 }
        if (!printed) { print "error: section \"" heading "\" is empty" > "/dev/stderr"; exit 1 }
    }
' "$changelog"
