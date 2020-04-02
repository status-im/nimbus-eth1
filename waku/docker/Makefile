SHELL := bash # the shell used internally by "make"

# These default settings can be overriden by exporting env variables

GIT_REVISION ?= $(shell git rev-parse HEAD)

IMAGE_TAG       ?= latest
IMAGE_NAME      ?= statusteam/nimbus_wakunode:$(IMAGE_TAG)

build:
	docker build \
		--build-arg="GIT_REVISION=$(GIT_REVISION)" \
		-t $(IMAGE_NAME) .

push: build
	docker push $(IMAGE_NAME)
