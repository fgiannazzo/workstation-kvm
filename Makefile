.PHONY: build test clean

# The Command Line Tools' SwiftPM does not resolve the Swift Testing macro plugin for every test
# target (docs/DESIGN.md, "Toolchain"), so build with Xcode's toolchain. If xcode-select still
# points at the CLT, select Xcode for this invocation only.
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
ifeq ($(DEVELOPER_DIR),)
ifneq ($(wildcard $(XCODE_DEVELOPER_DIR)),)
export DEVELOPER_DIR := $(XCODE_DEVELOPER_DIR)
endif
endif

# Verification for every pull request: build, then the hardware-free test suite.
build:
	swift build

test:
	swift test

clean:
	swift package clean
