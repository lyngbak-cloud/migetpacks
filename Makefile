.PHONY: help build build-alpine push push-alpine test test-detect test-build-vars test-build-meta test-inject-env test-nodejs test-python test-go test-rust test-dotnet clean install

# Variables
REGISTRY ?= miget
IMAGE_NAME ?= migetpacks
IMAGE_TAG ?= 0.0.282
PLATFORMS ?= linux/amd64,linux/arm64
FULL_IMAGE = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

help:
	@echo "migetpacks - Auto-detecting Buildpacks for Container Images"
	@echo ""
	@echo "Available targets:"
	@echo "  make build                - Build the builder container image"
	@echo "  make push                 - Push the builder image to registry"
	@echo "  make test                 - Run all tests"
	@echo "  make test-detect          - Run detection tests only"
	@echo "  make test-build-vars      - Run build-var name guard tests"
	@echo "  make test-nodejs          - Test Node.js example build"
	@echo "  make test-python          - Test Python example build"
	@echo "  make test-go              - Test Go example build"
	@echo "  make test-rust            - Test Rust example build"
	@echo "  make test-dotnet          - Test .NET example build"
	@echo "  make clean                - Remove build artifacts"
	@echo "  make install              - Install to Kubernetes (Shipwright)"
	@echo ""
	@echo "Environment variables:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  IMAGE_NAME=$(IMAGE_NAME)"
	@echo "  IMAGE_TAG=$(IMAGE_TAG)"

build:
	@echo "Building $(FULL_IMAGE) for $(PLATFORMS)..."
	docker buildx build --platform $(PLATFORMS) -t $(FULL_IMAGE) .
	@echo "✓ Build complete: $(FULL_IMAGE)"

push:
	@echo "Building and pushing $(FULL_IMAGE) for $(PLATFORMS)..."
	docker buildx build --platform $(PLATFORMS) -t $(FULL_IMAGE) -t $(REGISTRY)/$(IMAGE_NAME):latest --push .
	@echo "✓ Image pushed: $(FULL_IMAGE)"

build-alpine:
	@echo "Building $(FULL_IMAGE)-alpine for $(PLATFORMS)..."
	docker buildx build --platform $(PLATFORMS) -t $(FULL_IMAGE)-alpine -f Dockerfile.alpine .
	@echo "✓ Build complete: $(FULL_IMAGE)-alpine"

push-alpine:
	@echo "Building and pushing $(FULL_IMAGE)-alpine for $(PLATFORMS)..."
	docker buildx build --platform $(PLATFORMS) -t $(FULL_IMAGE)-alpine -t $(REGISTRY)/$(IMAGE_NAME):latest-alpine -f Dockerfile.alpine --push .
	@echo "✓ Image pushed: $(FULL_IMAGE)-alpine"

test-detect:
	@echo "Running detection tests..."
	./test/test-detect.sh

test-generate-secret:
	@echo "Running generate_secret tests..."
	./test/test-generate-secret.sh

test-build-vars:
	@echo "Running build-vars guard tests..."
	./test/test-build-vars.sh

test-build-meta:
	@echo "Running build-metadata helper tests..."
	./test/test-build-meta.sh

test-inject-env:
	@echo "Running custom env injection tests..."
	./test/test-inject-env.sh

test-nodejs:
	@echo "Testing Node.js build..."
	docker run --rm \
		-v $(PWD)/examples/nodejs-example:/workspace/source:ro \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e SOURCE_DIR=/workspace/source \
		-e OUTPUT_IMAGE=test-nodejs:latest \
		$(FULL_IMAGE)

test-python:
	@echo "Testing Python build..."
	docker run --rm \
		-v $(PWD)/examples/python-example:/workspace/source:ro \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e SOURCE_DIR=/workspace/source \
		-e OUTPUT_IMAGE=test-python:latest \
		$(FULL_IMAGE)

test-go:
	@echo "Testing Go build..."
	docker run --rm \
		-v $(PWD)/examples/go-example:/workspace/source:ro \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e SOURCE_DIR=/workspace/source \
		-e OUTPUT_IMAGE=test-go:latest \
		$(FULL_IMAGE)

test-rust:
	@echo "Testing Rust build..."
	docker run --rm \
		-v $(PWD)/examples/rust-example:/workspace/source:ro \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e SOURCE_DIR=/workspace/source \
		-e OUTPUT_IMAGE=test-rust:latest \
		$(FULL_IMAGE)

test-dotnet:
	@echo "Testing .NET build..."
	docker run --rm \
		-v $(PWD)/examples/dotnet-hello-world:/workspace/source:ro \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-e SOURCE_DIR=/workspace/source \
		-e OUTPUT_IMAGE=test-dotnet:latest \
		$(FULL_IMAGE)

test: test-detect test-generate-secret test-build-vars test-build-meta test-inject-env
	@echo "All tests passed ✓"

clean:
	@echo "Cleaning build artifacts..."
	docker rmi $(FULL_IMAGE) 2>/dev/null || true
	docker rmi test-nodejs:latest 2>/dev/null || true
	docker rmi test-python:latest 2>/dev/null || true
	docker rmi test-go:latest 2>/dev/null || true
	docker rmi test-rust:latest 2>/dev/null || true
	docker rmi test-dotnet:latest 2>/dev/null || true
	@echo "✓ Clean complete"

install:
	@echo "Installing ClusterBuildStrategy to Kubernetes..."
	kubectl apply -f shipwright/cluster-build-strategy.yaml
	@echo "✓ Installed successfully"
	@echo ""
	@echo "Create a build with:"
	@echo "  kubectl apply -f shipwright/examples/nodejs-build.yaml"

uninstall:
	@echo "Uninstalling ClusterBuildStrategy from Kubernetes..."
	kubectl delete -f shipwright/cluster-build-strategy.yaml --ignore-not-found
	@echo "✓ Uninstalled"
