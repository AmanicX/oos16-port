# ==============================================================================
# src/Makefile - Build helper for binderfs_init
# Target: ARM64 Linux static executable for Stage-1 ramdisks
# ==============================================================================

.PHONY: all arm64 host test c_test verify clean install

all: test arm64 verify

# Build standalone static ARM64 binary using Go (zero external libc dependencies)
arm64: binderfs_init_arm64

binderfs_init_arm64: binderfs_init.go
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o binderfs_init_arm64 binderfs_init.go
	chmod 0755 binderfs_init_arm64

# Build host binary for local testing
host: binderfs_init_host

binderfs_init_host: binderfs_init.go
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o binderfs_init_host binderfs_init.go
	chmod 0755 binderfs_init_host

# Run unit tests
test:
	go test -v ./...

# Verify strict C reference compilation
c_test:
	gcc -Wall -Wextra -Werror -pedantic -std=gnu11 -o /dev/null binderfs_init.c

# Verify ELF architecture and static linkage
verify: arm64
	@file binderfs_init_arm64 | grep -q "ARM aarch64" || (echo "ERROR: Output is not ARM aarch64!" && exit 1)
	@file binderfs_init_arm64 | grep -q "statically linked" || (echo "ERROR: Output is not statically linked!" && exit 1)
	@echo "Verification passed: binderfs_init_arm64 is static ELF 64-bit ARM aarch64."

install: arm64 verify
	cp binderfs_init_arm64 ../stage1/loader_ramdisk/system/bin/binderfs_init
	cp binderfs_init_arm64 ../stage1/native_ramdisk/system/bin/binderfs_init
	chmod 0755 ../stage1/loader_ramdisk/system/bin/binderfs_init
	chmod 0755 ../stage1/native_ramdisk/system/bin/binderfs_init
	cmp -s ../stage1/loader_ramdisk/system/bin/binderfs_init ../stage1/native_ramdisk/system/bin/binderfs_init
	cmp -s binderfs_init_arm64 ../stage1/loader_ramdisk/system/bin/binderfs_init
	@echo "Successfully installed and verified byte-identical binderfs_init across ramdisks."

clean:
	rm -f binderfs_init_arm64 binderfs_init_host
