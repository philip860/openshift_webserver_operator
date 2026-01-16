# Simplified Makefile for building operator image and bundle
IMG ?= quay.io/philip860/webserver-operator:v1.0.34-dev
BUNDLE_IMG ?= quay.io/philip860/webserver-operator-bundle:v1.0.34-dev
VERSION ?= v1.0.34-dev

all: docker-build docker-push

docker-build:
	podman build -t $(IMG) .

docker-push:
	podman push $(IMG)

manifests:
	@echo "Manifests are pre-generated in config/ and bundle/ for this example."

bundle:
	@echo "Bundle manifests are pre-generated in bundle/ for this example."

bundle-build:
	podman build -f bundle/Dockerfile -t $(BUNDLE_IMG) bundle

bundle-push:
	podman push $(BUNDLE_IMG)
