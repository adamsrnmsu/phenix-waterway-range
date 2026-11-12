# Generates phenix-arm64.Dockerfile from sceptre-phenix/docker/Dockerfile (make phenix-arm64.Dockerfile)
s/Linux_x86_64/Linux_arm64/g
s/filebeat-7\.17\.5-amd64\.deb/filebeat-7.17.5-arm64.deb/g
s#ghcr\.io/sandia-minimega/minimega:\${MM_MIN_REV}#minimega:arm64#
