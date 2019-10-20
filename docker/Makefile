# These default settings can be overriden by exporting env variables

GIT_REVISION    ?= $(git rev-parse HEAD)

IMAGE_TAG       ?= nimbus_latest
IMAGE_NAME      ?= statusteam/nimbus_beacon_node:$(IMAGE_TAG)

build: $(NIX_INSTALL)
	docker build \
		--build-arg="GIT_REVISION=$(GIT_REVISION)" \
		-t $(IMAGE_NAME) .

push: build
	docker push $(IMAGE_NAME)

