SHELL := /bin/bash

SUDO ?= sudo
WORKDIR ?= $(CURDIR)/out
IMAGE ?= $(or $(TARGET_IMG),$(target_img))
OUTPUT_IMAGE := $(or $(OUTPUT_IMG),$(output_img))

.PHONY: help ext4 btrfs copy xz

help:
	@printf '%s\n' \
	  'make ext4                          Build a new ext4 cloud image' \
	  'make btrfs                         Build a new btrfs cloud image' \
	  'make copy TARGET_IMG=out/img.qcow2 Copy config into an existing qcow2 image' \
	  'make xz TARGET_IMG=out/img.qcow2   Convert qcow2 to raw.xz'

ext4:
	$(SUDO) ./scripts/image/build-image-ext4.sh

btrfs:
	$(SUDO) ./scripts/image/build-image-btrfs.sh

copy:
	@if [[ -z "$(IMAGE)" ]]; then echo 'Set TARGET_IMG=/path/to/image.qcow2 or target_img=/path/to/image.qcow2'; exit 1; fi
	$(SUDO) ./scripts/image/copy-config-to-qcow2.sh "$(IMAGE)"

xz:
	@if [[ -z "$(IMAGE)" ]]; then echo 'Set TARGET_IMG=/path/to/image.qcow2 or target_img=/path/to/image.qcow2'; exit 1; fi
	@if [[ -n "$(OUTPUT_IMAGE)" ]]; then \
	  WORKDIR="$(WORKDIR)" ./scripts/image/export-qcow2-to-raw-xz.sh "$(IMAGE)" "$(OUTPUT_IMAGE)"; \
	else \
	  WORKDIR="$(WORKDIR)" ./scripts/image/export-qcow2-to-raw-xz.sh "$(IMAGE)"; \
	fi
