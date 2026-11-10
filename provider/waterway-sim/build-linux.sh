#!/usr/bin/env bash
# Build simulinksolver (aarch64-unknown-linux-gnu, glibc 2.35) in a jammy container inside the Lima VM "phenix".
# Must be glibc, not musl: POSIX named semaphores in /dev/shm are shared with the glibc bennu-simulink-provider and
# musl's sem_t layout is incompatible. jammy = the guest images' glibc, so the binary runs on every guest.
# ~/git is mounted at the same path in the VM, so output lands in ./dist/simulinksolver on the Mac.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
limactl shell phenix -- bash -lc "
  set -euo pipefail
  if ! command -v cargo >/dev/null && [ ! -x \$HOME/.cargo/bin/cargo ]; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
  fi
  sudo docker run --rm -v \$HOME/.cargo:/cargo -v \$HOME/.rustup:/rustup -e CARGO_HOME=/cargo -e RUSTUP_HOME=/rustup \
    -v '$here':/src -w /src -e CARGO_TARGET_DIR=/src/target-linux ubuntu:22.04 bash -c '
      apt-get update -qq && apt-get install -y -qq gcc file >/dev/null
      /cargo/bin/cargo build --release
      mkdir -p dist && cp target-linux/release/simulinksolver dist/simulinksolver
      file dist/simulinksolver; objdump -T dist/simulinksolver 2>/dev/null | grep -o \"GLIBC_[0-9.]*\" | sort -uV | tail -1'
"
