#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: remote-build.sh <name>

Expects ~/lpc-build-<name>/lpc.tgz. Clears the old tree in that dir,
extracts the tarball, copies Vendor/libwolfssl.a and Vendor/wolfssl
from ~/lpc-build, removes .theos dirs and runs
`THEOS=~/theos make package FINALPACKAGE=1`. The full log stays in
~/lpc-build-<name>/build.log.

stdout: {"status":"ok|fail","make_exit":N,"errors":[..],"undefined":[..],"deb":"..","log":".."}
        a failure also adds "tail": the last 15 log lines
exit 0 when status is ok, 1 when the build fails, 2 on bad arguments.
EOF
}

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    [[ $# -ge 1 ]] && exit 0 || exit 2
fi

name="$1"
# a bad name could resolve to the shared ~/lpc-build dir, which holds the vendor copy
if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    echo "remote-build.sh: bad name '$name'" >&2
    exit 2
fi

base="$HOME/lpc-build"
dir="$HOME/lpc-build-$name"
log="$dir/build.log"

fail_early() {
    jq -n --arg msg "$1" '{status: "fail", make_exit: -1, errors: [$msg], undefined: [], deb: "", log: "", tail: []}'
    exit 1
}

[[ -f "$dir/lpc.tgz" ]] || fail_early "missing $dir/lpc.tgz"
[[ -f "$base/Vendor/libwolfssl.a" && -d "$base/Vendor/wolfssl" ]] || fail_early "missing vendor copy in $base/Vendor"
[[ -d "$HOME/theos" ]] || fail_early "missing ~/theos"
# a non-login ssh shell has no brew path, and theos signs with ldid from there
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
command -v ldid >/dev/null || fail_early "ldid not on PATH"

cd "$dir" || fail_early "cannot cd to $dir"

# old files from a previous build would hide a removed source file
find . -mindepth 1 -maxdepth 1 ! -name lpc.tgz ! -name remote-build.sh -exec rm -rf {} +
tar -xzf lpc.tgz || fail_early "tar extract failed"

mkdir -p Vendor
cp "$base/Vendor/libwolfssl.a" Vendor/
rm -rf Vendor/wolfssl
cp -R "$base/Vendor/wolfssl" Vendor/
find . -name .theos -type d -prune -exec rm -rf {} +

THEOS="$HOME/theos" make package FINALPACKAGE=1 > "$log" 2>&1
make_exit=$?

errors_json="$(grep -n 'error:' "$log" | head -40 | jq -R . | jq -s .)"
undefined_json="$(grep -n -A3 'Undefined' "$log" | head -40 | jq -R . | jq -s .)"
tail_json="$(tail -n 15 "$log" | sed $'s/\x1b\\[[0-9;]*m//g' | jq -R . | jq -s .)"
deb="$(ls -t packages/*.deb 2>/dev/null | head -1)"
[[ -n "$deb" ]] && deb="$dir/$deb"

status="fail"
if [[ $make_exit -eq 0 && "$errors_json" == "[]" && "$undefined_json" == "[]" && -n "$deb" ]]; then
    status="ok"
fi

jq -n --arg status "$status" --argjson make_exit "$make_exit" \
    --argjson errors "$errors_json" --argjson undefined "$undefined_json" \
    --argjson tail "$tail_json" --arg deb "$deb" --arg log "$log" \
    '{status: $status, make_exit: $make_exit, errors: $errors, undefined: $undefined, deb: $deb, log: $log}
     + (if $status == "ok" then {} else {tail: $tail} end)'

[[ "$status" == "ok" ]]
