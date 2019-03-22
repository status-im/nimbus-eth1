# These default settings can be overriden by exporting env variables
NETWORK         ?= testnet0
NETWORK_BACKEND ?= rlpx

IMAGE_TAG       ?= $(NETWORK)-$(NETWORK_BACKEND)
IMAGE_NAME      ?= statusteam/nimbus_beacon_node:$(IMAGE_TAG)

build: $(NIX_INSTALL)
	docker build \
		--build-arg="NETWORK=$(NETWORK)" \
		--build-arg="NETWORK_BACKEND=$(NETWORK_BACKEND)" \
		-t $(IMAGE_NAME) .

push: build
	docker push $(IMAGE_NAME)
