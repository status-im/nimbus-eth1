# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

SHELL := bash

IMAGE_TAG := dist_base_eth1_v2
IMAGE_NAME := statusim/nimbus-eth1:$(IMAGE_TAG)

.PHONY: \
	build-linux-amd64 \
	build-linux-arm64 \
	build-windows-amd64 \
	build-macos-arm64 \
	push-linux-amd64 \
	push-linux-arm64 \
	push-windows-amd64 \
	push-macos-arm64

build-linux-amd64:
	$(CURDIR)/make_base_image.sh linux-amd64 "$(IMAGE_NAME)_linux_amd64"

build-linux-arm64:
	$(CURDIR)/make_base_image.sh linux-arm64 "$(IMAGE_NAME)_linux_arm64"

build-windows-amd64:
	$(CURDIR)/make_base_image.sh windows-amd64 "$(IMAGE_NAME)_windows_amd64"

build-macos-arm64:
	$(CURDIR)/make_base_image.sh macos-arm64 "$(IMAGE_NAME)_macos_arm64"

# You probably don't want to recreate and push these base images to Docker Hub,
# because when older images expire and get deleted, it will no longer be possible
# to reproduce old releases.
#
# When you really have to, change the Docker tags by appending "_v2", "_v3", etc. to them.
# This way you won't overwrite the old image.

push-linux-amd64: build-linux-amd64
	docker push $(IMAGE_NAME)_linux_amd64

push-linux-arm64: build-linux-arm64
	docker push $(IMAGE_NAME)_linux_arm64

push-windows-amd64: build-windows-amd64
	docker push $(IMAGE_NAME)_windows_amd64

push-macos-arm64: build-macos-arm64
	docker push $(IMAGE_NAME)_macos_arm64
