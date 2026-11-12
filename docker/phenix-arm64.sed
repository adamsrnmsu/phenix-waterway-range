# Generates phenix-arm64.Dockerfile from sceptre-phenix/docker/Dockerfile (make phenix-arm64.Dockerfile)
s/Linux_x86_64/Linux_arm64/g
s/filebeat-\${FILEBEAT_VERSION}-amd64\.deb/filebeat-${FILEBEAT_VERSION}-arm64.deb/g
s#ghcr\.io/sandia-minimega/minimega:\${MM_MIN_REV}#minimega:arm64#
# Upstream pins amd64 checksums; swap each for the arm64 artifact's, keyed on the exact amd64 value so a version
# bump upstream fails the Makefile check instead of building with a stale hash.
# glow 3.0.0: github.com/charmbracelet/glow/releases/download/v3.0.0/checksums.txt
s/13e05e4b2acc18d2aee44291aefe6325b077ec321b631a0cfa780e8e3bc33f78/810c39f4691feb75e675a5f5f54b9fa091354e7599d9cf9c9fc9b97e47a99759/
# filebeat 7.17.29: artifacts.elastic.co/downloads/beats/filebeat/filebeat-7.17.29-arm64.deb.sha512
s/9dedc942dd2c8cc1ae2b3728b130e68d9bf82e91b1815f25d4bf3249ddba3916ebb8c0dc0b7f6e9d9d65edb3f9ece0dba166b7d9e61ec625e71430aafede544d/ac30514a352d1649b62c31df1d44ed11cdaf3ec5e47b612971216a3a9fcc3fd494f49f07a5152d6723475006bcb488f23c5054dfe225d294e6ecab73b358e730/
