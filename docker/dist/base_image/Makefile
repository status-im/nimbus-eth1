SHELL := bash

IMAGE_TAG := dist_base_eth1_$(shell date --utc +"%Y%m%d%H%M%S")
IMAGE_NAME := statusteam/nimbus-eth1:$(IMAGE_TAG)

.PHONY: \
	build-amd64 \
	build-arm64 \
	build-arm \
	build-win64 \
	build-macos \
	push-amd64 \
	push-arm64 \
	push-arm \
	push-win64 \
	push-macos

build-amd64:
	$(CURDIR)/make_base_image.sh amd64 "$(IMAGE_NAME)"

build-arm64:
	$(CURDIR)/make_base_image.sh arm64 "$(IMAGE_NAME)_arm64"

build-arm:
	$(CURDIR)/make_base_image.sh arm "$(IMAGE_NAME)_arm"

build-win64:
	$(CURDIR)/make_base_image.sh win64 "$(IMAGE_NAME)_win64"

build-macos:
	$(CURDIR)/make_base_image.sh macos "$(IMAGE_NAME)_macos"

# You probably don't want to recreate and push these base images to Docker Hub,
# because when older images expire and get deleted, it will no longer be possible
# to reproduce old releases.
#
# When you really have to, change the Docker tags by appending "_v2", "_v3", etc. to them.
# This way you won't overwrite the old image.

#push-amd64: build-amd64
	#docker push $(IMAGE_NAME)

#push-arm64: build-arm64
	#docker push $(IMAGE_NAME)_arm64

#push-arm: build-arm
	#docker push $(IMAGE_NAME)_arm

#push-win64: build-win64
	#docker push $(IMAGE_NAME)_win64

#push-macos: build-macos
	#docker push $(IMAGE_NAME)_macos

