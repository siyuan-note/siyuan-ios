#!/bin/sh
# Regenerate app/zoneinfo.zip from an IANA tz release, using the Go toolchain's own recipe
# (make line and mkzip.go from $GOROOT/lib/time/update.bash). On iOS the kernel loads this file
# through ZONEINFO (kernel/mobile/kernel.go SetTimezone), so it must follow IANA releases.
#
# usage: scripts/update-zoneinfo.sh 2026e
set -eu
V=${1:?usage: $0 TZ_VERSION (for example 2026e)}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
go build -o mkzip "$(go env GOROOT)/lib/time/mkzip.go"
for f in "tzcode$V.tar.gz" "tzdata$V.tar.gz"; do
	curl -sSfL -O "https://data.iana.org/time-zones/releases/$f"
done
tar xzf "tzcode$V.tar.gz"
tar xzf "tzdata$V.tar.gz"
mkdir zoneinfo
make CFLAGS=-DSTD_INSPIRED AWK=awk TZDIR=zoneinfo PACKRATDATA=backzone PACKRATLIST=zone.tab posix_only >make.out 2>&1 || {
	cat make.out
	exit 2
}
cd zoneinfo
../mkzip "$root/app/zoneinfo.zip"
echo "app/zoneinfo.zip regenerated from tzdata $V"
