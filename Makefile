.PHONY: build test clean

# Verification for every pull request: build, then the hardware-free test suite.
build:
	swift build

test:
	swift test

clean:
	swift package clean
