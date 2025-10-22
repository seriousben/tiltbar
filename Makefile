# Makefile for TiltBar
# Simple commands for building and running the TiltBar app

.DEFAULT_GOAL := help

# Setup: Download and convert Tilt icons from running Tilt instance (optional)
# Note: Fallback icons are bundled in the repository
# Only needed if you want to update icons from a running Tilt instance
# Requires: Tilt running on localhost:10350
.PHONY: setup
setup:
	@echo "Downloading Tilt icons from running Tilt instance..."
	@mkdir -p Sources/TiltBar/Resources
	@if curl -s -f http://localhost:10350/static/ico/favicon-green.ico -o Sources/TiltBar/Resources/tilt-icon.ico; then \
		curl -s -f http://localhost:10350/static/ico/favicon-gray.ico -o Sources/TiltBar/Resources/tilt-gray.ico; \
		curl -s -f http://localhost:10350/static/ico/favicon-red.ico -o Sources/TiltBar/Resources/tilt-red.ico; \
		echo "Converting icons to PNG..."; \
		sips -s format png Sources/TiltBar/Resources/tilt-icon.ico --out Sources/TiltBar/Resources/tilt-icon.png > /dev/null 2>&1; \
		sips -s format png Sources/TiltBar/Resources/tilt-gray.ico --out Sources/TiltBar/Resources/tilt-gray.png > /dev/null 2>&1; \
		sips -s format png Sources/TiltBar/Resources/tilt-red.ico --out Sources/TiltBar/Resources/tilt-red.png > /dev/null 2>&1; \
		echo "✓ Icons downloaded and converted"; \
	else \
		echo "⚠ Could not connect to Tilt (http://localhost:10350)"; \
		echo "  Using bundled fallback icons"; \
	fi

# Build: Compile in release mode (optimized binary)
.PHONY: build
build:
	@echo "Building TiltBar (release)..."
	@swift build -c release
	@mkdir -p .build/release/Resources
	@cp Sources/TiltBar/Resources/*.png .build/release/Resources/ 2>/dev/null || true
	@echo "✓ Build complete: .build/release/TiltBar"

# Build-debug: Compile in debug mode (faster, includes debug symbols)
.PHONY: build-debug
build-debug:
	@echo "Building TiltBar (debug)..."
	@swift build
	@mkdir -p .build/debug/Resources
	@cp Sources/TiltBar/Resources/*.png .build/debug/Resources/ 2>/dev/null || true
	@echo "✓ Build complete: .build/debug/TiltBar"

# Run: Build and run the app in debug mode
.PHONY: run
run: build-debug
	@echo "Running TiltBar..."
	@./.build/debug/TiltBar

# Clean: Remove all build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@swift package clean
	@echo "✓ Clean complete"

# Run-release: Build and run in release mode (optimized)
.PHONY: run-release
run-release: build
	@echo "Running TiltBar (release)..."
	@./.build/release/TiltBar

# Help: Show available commands
.PHONY: help
help:
	@echo "TiltBar - Available Commands"
	@echo ""
	@echo "Setup (optional):"
	@echo "  make setup         Update icons from running Tilt instance"
	@echo "                     (Fallback icons are already bundled)"
	@echo ""
	@echo "Build & Run:"
	@echo "  make build         Build optimized release binary"
	@echo "  make run           Build and run in debug mode (recommended)"
	@echo "  make run-release   Build and run in release mode"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean         Remove build artifacts"
	@echo "  make help          Show this help"
	@echo ""
	@echo "Quick start: make run"
