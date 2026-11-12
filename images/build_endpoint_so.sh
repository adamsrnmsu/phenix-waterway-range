#!/bin/sh
# Rebuild pybennu's vendored x86 swig/_Endpoint.so for aarch64 (README in pybennu/distributed/swig). Run inside bennu:arm64.
set -ex
apt-get update && apt-get install -y --no-install-recommends swig
cd /tmp && cp /usr/local/lib/python3.10/dist-packages/pybennu/distributed/swig/Endpoint.i .
swig -c++ -python Endpoint.i
g++ -O2 -fPIC -shared Endpoint_wrap.cxx -I/usr/include/python3.10 -o _Endpoint.so
cp _Endpoint.so /out/_Endpoint.so
