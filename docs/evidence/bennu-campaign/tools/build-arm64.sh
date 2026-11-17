#!/usr/bin/env bash
# build-arm64.sh <src-tree> <volume> <out.tgz> : native arm64 build of bennu in the jammy build image, install bundle as tgz
set -eo pipefail
SRC=$(cd "$1" && pwd); VOL=$2; OUT=$3
mkdir -p "$(dirname "$OUT")"
docker run --rm -v "$SRC:/src:ro" -v "$VOL:/cache" -v "$(dirname "$OUT"):/out" bennu-build:fix-fd-ack-flap-arm64 bash -c "
set -e
mkdir -p /cache/src /cache/build
rsync -a --delete --exclude .git --exclude build /src/ /cache/src/ 2>/dev/null || cp -a /src/. /cache/src/
cd /cache/build && cmake -D BUILD_GOBENNU=OFF /cache/src >/dev/null && make -j\${JOBS:-6} 2>&1 | tail -3
rm -rf /tmp/stage && make install DESTDIR=/tmp/stage >/dev/null
tar -C /tmp/stage -czf /out/$(basename "$OUT") usr
echo built /out/$(basename "$OUT")"
