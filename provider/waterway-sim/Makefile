.PHONY: test build linux
test:
	cargo test
build:
	cargo build --release
linux:  # glibc-2.35 aarch64 binary built in a jammy container in the Lima VM -> dist/simulinksolver
	./build-linux.sh
