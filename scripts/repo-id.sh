#!/usr/bin/env bash
# Print the repo id used to label shared-memory entries: lowercase `org/name`
# from the normalized git remote (`upstream` if present, else `origin`).
# Clones differ in remote scheme, directory and worktree path; only the remote is
# stable. Exits 1 with no output when there is no remote or it does not normalize
# to a valid id, so a caller can skip labelling instead of inventing one.
#
# Usage: repo-id.sh [dir]

set -euo pipefail

dir="${1:-.}"
url=""
for remote in upstream origin; do
  url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null || true)
  [ -n "$url" ] && break
done
[ -n "$url" ] || exit 1

# Local paths and drive letters are not an org/name.
case "$url" in file:*|/*|.*|[A-Za-z]:[/\\]*) exit 1 ;; *:*) ;; *) exit 1 ;; esac
path="${url%/}"
case "$path" in *.[gG][iI][tT]) path="${path%.???}" ;; esac
case "$path" in
  *://*) path="${path#*://}"; path="${path#*/}" ;;
  *:*)   path="${path#*:}" ;;
esac
path="${path#/}"

# Exactly `org/name`. A deeper path (GitLab subgroups, Azure DevOps) would
# collapse to its last two segments and give different repos one id.
case "$path" in */*/*|/*|*/|"") exit 1 ;; */*) ;; *) exit 1 ;; esac
org="${path%%/*}"
name="${path#*/}"

# Non-ASCII is rejected before lowercasing: tr would map look-alikes (the Kelvin
# sign to `k`) onto a valid id.
LC_ALL=C
case "$org$name" in *[!A-Za-z0-9._-]*) exit 1 ;; esac
org=$(printf '%s' "$org" | tr 'A-Z' 'a-z')
name=$(printf '%s' "$name" | tr 'A-Z' 'a-z')

[[ "$org" =~ ^[a-z0-9][a-z0-9-]{0,38}$ ]] || exit 1
[[ "$name" =~ ^[a-z0-9._-]{1,100}$ ]] || exit 1
[ "$name" != "." ] && [ "$name" != ".." ] || exit 1
id="$org/$name"
# The shared scopes are reserved ids: a real repo of the same name must not
# silently become one of them.
for reserved in "${MEGAVIBE_MEMORY_GENERAL:-}" "${MEGAVIBE_MEMORY_COMPANY:-}"; do
  reserved=$(printf '%s' "$reserved" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
  reserved="${reserved%/}"; reserved="${reserved%.git}"
  [ -z "$reserved" ] || [ "$id" != "$reserved" ] || exit 1
done
printf '%s\n' "$id"
