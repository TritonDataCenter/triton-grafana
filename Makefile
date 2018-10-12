#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

GO_PREBUILT_VERSION = 1.11.1
NODE_PREBUILT_VERSION = v8.11.3

ifeq ($(shell uname -s),SunOS)
    NODE_PREBUILT_TAG=zone
	# Allow building on other than sdc-minimal-multiarch-lts@15.4.1
	NODE_PREBUILT_IMAGE=18b094b0-eb01-11e5-80c1-175dac7ddf02
endif

include ./tools/mk/Makefile.defs
include ./tools/mk/Makefile.smf.defs

ifeq ($(shell uname -s),SunOS)
    include ./tools/mk/Makefile.go_prebuilt.defs
    include ./tools/mk/Makefile.node_prebuilt.defs
endif

SERVICE_NAME = grafana
RELEASE_TARBALL := $(SERVICE_NAME)-pkg-$(STAMP).tar.bz2
RELSTAGEDIR := /tmp/$(STAMP)
SMF_MANIFESTS = smf/manifests/grafana.xml

GRAFANA_IMPORT = github.com/grafana/grafana
GRAFANA_GO_DIR = $(GO_GOPATH)/src/$(GRAFANA_IMPORT)
GRAFANA_EXEC = $(GO_GOPATH)/bin/grafana-server

YARN = ./node_modules/.bin/yarn

#
# Repo-specific targets
#
.PHONY: all
all: $(GRAFANA_EXEC)

#
# Link the "pg_prefaulter" submodule into the correct place within our
# project-local GOPATH, then build the binary.
#
$(GRAFANA_EXEC): deps/grafana/.git $(STAMP_GO_TOOLCHAIN) | $(NPM_EXEC)
	$(GO) version
	mkdir -p $(dir $(GRAFANA_GO_DIR))
	rm -f $(GRAFANA_GO_DIR)
	ln -s $(TOP)/deps/grafana $(GRAFANA_GO_DIR)
	(cd $(GRAFANA_GO_DIR) && \
		env -i $(GO_ENV) \
		$$($(GO) run build.go setup && \
		$(GO) run build.go build && \
		$(NPM) install yarn && \
		$(YARN) install --pure-lockfile && \
		$(YARN) dev))

.PHONY: release
release: all deps docs $(SMF_MANIFESTS)
	@echo "Building $(RELEASE_TARBALL)"
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)
	cp -r \
		$(TOP)/bin \
		$(TOP)/package.json \
		$(TOP)/smf \
		$(TOP)/sapi_manifests \
		$(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/
	# our grafana build
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/grafana
	cp -r \
		$(GRAFANA_GO_DIR)/bin/solaris-amd64/grafana-server \
		$(GRAFANA_GO_DIR)/public \
		$(RELSTAGEDIR)/root/opt/triton/$(SERVICE_NAME)/grafana/
	# zone boot
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot
	cp -r $(TOP)/deps/sdc-scripts/{etc,lib,sbin,smf} \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	cp -r $(TOP)/boot/* \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	# tar it up
	(cd $(RELSTAGEDIR) && $(TAR) -jcf $(TOP)/$(RELEASE_TARBALL) root)
	@rm -rf $(RELSTAGEDIR)


.PHONY: publish
publish: release
	@if [[ -z "$(BITS_DIR)" ]]; then \
		echo "error: 'BITS_DIR' must be set for 'publish' target"; \
		exit 1; \
	fi
	mkdir -p $(BITS_DIR)/$(SERVICE_NAME)
	cp $(TOP)/$(RELEASE_TARBALL) $(BITS_DIR)/$(SERVICE_NAME)/$(RELEASE_TARBALL)

.PHONY: dumpvar
dumpvar:
	@if [[ -z "$(VAR)" ]]; then \
		echo "error: set 'VAR' to dump a var"; \
		exit 1; \
	fi
	@echo "$(VAR) is '$($(VAR))'"

mytarget:
	echo my command

ifeq ($(shell uname -s),SunOS)
	include ./tools/mk/Makefile.go_prebuilt.targ
	include ./tools/mk/Makefile.node_prebuilt.targ
endif
include ./tools/mk/Makefile.smf.targ
include ./tools/mk/Makefile.targ
