#!/usr/bin/env bash
# Print the CHANGELOG.md section for a version (e.g. 0.5.0), from its
# "## [X] - date" heading up to the next "## [" heading. Exits 1 if missing.
# If CHANGELOG.md has a top-level "Known limits" section, it is appended.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
version="${1#v}"
root="$(cd "$(dirname "$0")/.." && pwd)"
changelog="$root/CHANGELOG.md"

if ! grep -qF "## [$version]" "$changelog"; then
  echo "error: version $version not found in CHANGELOG.md" >&2
  exit 1
fi

section="$(awk -v v="$version" '
  /^## \[/ {
    if (found) exit
    if (index($0, "## [" v "]") == 1) { found = 1; next }
  }
  found { print }
' "$changelog")"

# Trim leading and trailing blank lines.
printf '%s\n' "$section" | awk 'NF { started = 1 } started { buf[++n] = $0 } END { while (n > 0 && buf[n] == "") n--; for (i = 1; i <= n; i++) print buf[i] }'

# "Known limits" passthrough, when present outside the version sections.
limits="$(awk '
  /^##+ Known limits/ { p = 1; print; next }
  p && /^## / { exit }
  p { print }
' "$changelog")"
if [ -n "$limits" ] && ! printf '%s' "$section" | grep -q 'Known limits'; then
  printf '\n%s\n' "$limits"
fi
