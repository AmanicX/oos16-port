# ==============================================================================
# src/Makefile - Build helper for binderfs_init
# Target: ARM64 Linux static executable for Stage-1 ramdisks
# ==============================================================================

.PHONY: all arm64 host clean install

all: arm64

# Build standalone static ARM64 binary using Go (zero external libc dependencies)
arm64: binderfs_init_arm64

binderfs_init_arm64: binderfs_init.go
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o binderfs_init_arm64 binderfs_init.go
	chmod 0755 binderfs_init_arm64

# Optional C cross-compilation with aarch64-linux-gnu-gcc if installed:
# aarch64-linux-gnu-gcc -static -O2 -Wall -s -o binderfs_init_c_arm64 binderfs_init.c

# Build host binary for local unit testing
host: binderfs_init_host

binderfs_init_host: binderfs_init.go
	CGO_ENABLED=0 go build -ldflags="-s -w" -o binderfs_init_host binderfs_init.go
	chmod 0755 binderfs_init_host

install: arm64
	cp binderfs_init_arm64 ../stage1/loader_ramdisk/system/bin/binderfs_init
	cp binderfs_init_arm64 ../stage1/native_ramdisk/system/bin/binderfs_init
	chmod 0755 ../stage1/loader_ramdisk/system/bin/binderfs_init
	chmod 0755 ../stage1/native_ramdisk/system/bin/binderfs_init
	@echo "Successfully installed binderfs_init into loader_ramdisk and native_ramdisk."

clean:
	rm -f binderfs_init_arm64 binderfs_init_host
