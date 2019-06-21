# These default settings can be overriden by exporting env variables

GIT_REVISION    ?= $(git rev-parse HEAD)

NETWORK         ?= testnet0
NETWORK_BACKEND ?= rlpx

IMAGE_TAG       ?= $(NETWORK)
IMAGE_NAME      ?= statusteam/nimbus_beacon_node:$(IMAGE_TAG)

build: $(NIX_INSTALL)
	docker build \
		--build-arg="GIT_REVISION=$(GIT_REVISION)" \
		--build-arg="NETWORK=$(NETWORK)" \
		--build-arg="NETWORK_BACKEND=$(NETWORK_BACKEND)" \
		-t $(IMAGE_NAME) .

push: build
	docker push $(IMAGE_NAME)
