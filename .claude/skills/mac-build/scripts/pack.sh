#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: pack.sh <name> [repo_root]

  name       build name, [a-z0-9][a-z0-9-]{0,39}; the mac dir is ~/lpc-build-<name>
  repo_root  tree to pack (default: git toplevel of the current directory)

Writes <tmpdir>/lpc.tgz without docs, .git, .theos, packages and .claude.
stdout: {"name":..,"tarball":..,"bytes":..,"remote_dir":"lpc-build-<name>" (under the mac home dir)}
exit 0 on success, 2 on bad arguments, 1 on any other failure.
EOF
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    [[ $# -ge 1 ]] && exit 0 || exit 2
fi

name="$1"
# the name becomes a directory on the mac, so keep it strict
if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    echo "pack.sh: bad name '$name'" >&2
    exit 2
fi

root="${2:-$(git rev-parse --show-toplevel)}"
if [[ ! -f "$root/Makefile" || ! -f "$root/control" ]]; then
    echo "pack.sh: $root is not the LegacyPodClaw root" >&2
    exit 1
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/lpc-pack-$name.XXXXXX")"
tarball="$out_dir/lpc.tgz"

# excludes match the mac build procedure; vendor wolfssl is replaced on the mac
tar -czf "$tarball" -C "$root" \
    --exclude='./docs' \
    --exclude='.git' \
    --exclude='.theos' \
    --exclude='./packages' \
    --exclude='./.claude' \
    .

bytes="$(wc -c < "$tarball" | tr -d ' ')"
jq -n --arg name "$name" --arg tarball "$tarball" --argjson bytes "$bytes" \
    --arg remote_dir "lpc-build-$name" \
    '{name: $name, tarball: $tarball, bytes: $bytes, remote_dir: $remote_dir}'
