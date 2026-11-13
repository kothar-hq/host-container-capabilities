#!/usr/bin/env bash
# Verifies that all GitHub Actions workflow steps pin actions to a major-version tag
# (e.g. @v3), not a full 40-character SHA hash.
set -euo pipefail

failures=0

while IFS= read -r file; do
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        if printf '%s' "$line" | grep -qE 'uses:[[:space:]].*@[0-9a-f]{40}([^0-9a-f]|$)'; then
            printf '%s:%d: error: action pinned to SHA; use a major-version tag (e.g. @v3)\n' "$file" "$lineno" >&2
            printf '  %s\n' "$line" >&2
            failures=$((failures + 1))
        fi
    done < "$file"
done < <(find .github/workflows \( -name '*.yml' -o -name '*.yaml' \) | sort)

if [ "$failures" -gt 0 ]; then
    printf '\n%d SHA-pinned action(s) found. Pin to a major-version tag instead (e.g. @v3).\n' "$failures" >&2
    exit 1
fi

printf 'All action references use version tags.\n'
