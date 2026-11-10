# Derived from the locally built, unchanged upstream image: docker build -t minimega:arm64 -f ~/git/minimega/docker/Dockerfile ~/git/minimega
FROM minimega:arm64
# qemu-system-x86 for x86 guests (plan Decision 2-A); qemu-efi-aarch64 provides AAVMF firmware
RUN apt-get update \
  && apt-get install -y --no-install-recommends qemu-efi-aarch64 qemu-system-x86 qemu-system-arm \
  && apt-get clean -y && rm -rf /var/lib/apt/lists/*
COPY kvm-wrapper.sh /usr/local/bin/kvm
RUN chmod +x /usr/local/bin/kvm
