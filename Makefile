#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2020 Joyent, Inc.
# Copyright 2025 MNX Cloud, Inc.
#

NAME = grafana

# Use gcc10 instead of default gcc7, want __illumos__ macro
# See: https://github.com/golang/go/issues/67353
# Remove when updating BASE_IMAGE_UUID to 24.4.1+
GO_ENV += CC=/opt/local/gcc10/bin/gcc
GO_PREBUILT_VERSION = 1.22.12
GO_GOOS = illumos
NODE_PREBUILT_VERSION = v6.17.1
ifeq ($(shell uname -s),SunOS)
    # We use a 64-bit node because grafana will not build with 32-bit node 6
    NODE_PREBUILT_TAG=zone64
    # minimal-64-lts 24.4.1
    NODE_PREBUILT_IMAGE=41bd4100-eb86-409a-85b0-e649aadf6f62
    NODE_PREBUILT_BRANCH=TRITON-2479
endif

ENGBLD_USE_BUILDIMAGE = true
ENGBLD_REQUIRE := $(shell git submodule update --init deps/eng)
include ./deps/eng/tools/mk/Makefile.defs
TOP ?= $(error Unable to access eng.git submodule Makefiles.)

BUILD_PLATFORM  = 20210826T002459Z

include ./deps/eng/tools/mk/Makefile.smf.defs
# this is NOT A TYPO - the nginx makefiles are local, for now.
include ./tools/mk/Makefile.nginx.defs
ifeq ($(shell uname -s),SunOS)
    include ./deps/eng/tools/mk/Makefile.go_prebuilt.defs
    include ./deps/eng/tools/mk/Makefile.node_prebuilt.defs
    include ./deps/eng/tools/mk/Makefile.agent_prebuilt.defs
endif

#  triton-origin-x86_64-24.4.1
BASE_IMAGE_UUID =  4dd8810e-10a8-49d1-b37b-1c4e32ed6c05 
BUILDIMAGE_NAME = $(NAME)
BUILDIMAGE_PKGSRC = pcre-8.45 bind-9.16.50
BUILDIMAGE_DESC = SDC Grafana
AGENTS = amon config registrar

RELEASE_TARBALL := $(NAME)-pkg-$(STAMP).tar.gz
RELSTAGEDIR := /tmp/$(NAME)-$(STAMP)

SMF_MANIFESTS = $(wildcard smf/manifests/*.xml)

JS_FILES := $(wildcard lib/*.js) $(wildcard test/*.js)
ESLINT_FILES := $(JS_FILES)
BASH_FILES := $(wildcard boot/*.sh) $(wildcard bin/*.sh) $(TOP)/test/runtests

STAMP_PROXY := $(MAKE_STAMPS_DIR)/graf-proxy

GRAFANA_IMPORT = github.com/grafana/grafana
GRAFANA_GO_DIR = $(GO_GOPATH)/src/$(GRAFANA_IMPORT)
GRAFANA_EXEC = $(GO_GOPATH)/bin/grafana-server

WIRE = $(TOP)/$(GO_GOPATH)/bin/wire

NGINX_CONFIG_FLAGS += \
	--with-http_auth_request_module \
	--with-http_ssl_module

#
# Repo-specific targets
#
.PHONY: all
all: $(GRAFANA_EXEC) $(NGINX_EXEC) $(STAMP_PROXY) sdc-scripts

#
# Link the "grafana" submodule into the correct place within our
# project-local GOPATH, then build the binary.
#
$(GRAFANA_EXEC): deps/grafana/.git $(STAMP_GO_TOOLCHAIN)
	$(GO) version
	mkdir -p $(dir $(GRAFANA_GO_DIR))
	rm -rf $(GRAFANA_GO_DIR)
	cp -r $(TOP)/deps/grafana $(GRAFANA_GO_DIR)
	(cd $(GRAFANA_GO_DIR) && \
	    env -i $(GO_ENV) $(GO) install github.com/google/wire/cmd/wire@latest && \
	    env -i $(GO_ENV) $(WIRE) gen -tags oss ./pkg/server ./pkg/cmd/grafana-cli/runner && \
	    env -i $(GO_ENV) $(GO) run build.go build)

$(STAMP_PROXY): | $(NODE_EXEC) $(NPM_EXEC)
	$(MAKE_STAMP_REMOVE)
	rm -rf $(TOP)/node_modules && cd $(TOP) && $(NPM) install --production
	$(MAKE_STAMP_CREATE)

sdc-scripts: deps/sdc-scripts/.git

#
# Note that the current test suite is designed to run on an installed
# triton-grafana image, which will not contain this Makefile. Thus, unless this
# Makefile and its associated dependencies under "tools/mk" are manually copied
# to an installed image, `make test` will never do anything useful in any place
# where this Makefile exists. This could change in the future.
#
# Instead, it is sufficient to directly run `/opt/triton/grafana/test/runtests`
# in the installed image.
#
.PHONY: test
test:
	@#
	@# We check for the existence of the graf-proxy directory as a way of
	@# ascertaining whether we are in a dev or installation environment.
	@#
	@if [[ -f "$(TOP)/proxy" ]]; then \
		./test/runtests; \
	else \
		echo "Skipping tests: this is not an installation environment."; \
	fi

#
# The eng.git makefiles define the clean target using a :: rule. This
# means that we're allowed to have multiple bodies that define the rule
# and they should all take effect. We ignore the return value from the
# recursive make clean because there is no guarantee that there's a
# generated Makefile or that the nginx submodule has been initialized
# and checked out.
#
clean::
	@#
	@# Note: Grafana backend is cleaned when gopath is removed as part of
	@# general clean target.
	@# Note: nginx is cleaned as part of the `distclean` target in
	@# Makefile.nginx.targ
	@#
	# Clean Grafana frontend
	rm -rf $(TOP)/deps/grafana/node_modules
	rm -rf $(TOP)/deps/grafana/public/build
	# Clean graf-proxy
	rm -rf $(TOP)/node_modules

.PHONY: release
release: all deps docs $(SMF_MANIFESTS)
	@echo "Building $(RELEASE_TARBALL)"
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)
	cp -r \
		$(TOP)/bin \
		$(TOP)/etc \
		$(TOP)/dashboards \
		$(TOP)/package.json \
		$(TOP)/node_modules \
		$(TOP)/smf \
		$(TOP)/sapi_manifests \
		$(TOP)/test \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/
	# our grafana build
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)/grafana
	cp -r \
		$(GRAFANA_GO_DIR)/bin \
		$(GRAFANA_GO_DIR)/conf \
		$(GRAFANA_GO_DIR)/public \
		$(GRAFANA_GO_DIR)/scripts \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/grafana/
	# grafana auth proxy
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)/proxy
	cp -r \
		$(TOP)/lib \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/proxy
	# nginx
	cp -r \
		$(TOP)/build/nginx \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/
	# our node version
	@mkdir -p $(RELSTAGEDIR)/root/opt/triton/$(NAME)/build
	cp -r \
		$(TOP)/build/node \
		$(RELSTAGEDIR)/root/opt/triton/$(NAME)/build/
	# zone boot
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot
	cp -r $(TOP)/deps/sdc-scripts/{etc,lib,sbin,smf} \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	cp -r $(TOP)/boot/* \
		$(RELSTAGEDIR)/root/opt/smartdc/boot/
	# tar it up
	(cd $(RELSTAGEDIR) && $(TAR) -I pigz -cf $(TOP)/$(RELEASE_TARBALL) root)
	@rm -rf $(RELSTAGEDIR)

.PHONY: publish
publish: release
	mkdir -p $(ENGBLD_BITS_DIR)/$(NAME)
	cp $(TOP)/$(RELEASE_TARBALL) $(ENGBLD_BITS_DIR)/$(NAME)/$(RELEASE_TARBALL)

include ./deps/eng/tools/mk/Makefile.deps
ifeq ($(shell uname -s),SunOS)
    include ./deps/eng/tools/mk/Makefile.go_prebuilt.targ
    include ./deps/eng/tools/mk/Makefile.node_prebuilt.targ
    include ./deps/eng/tools/mk/Makefile.agent_prebuilt.targ
endif
include ./deps/eng/tools/mk/Makefile.smf.targ
# this is NOT A TYPO - the nginx makefiles are local, for now.
include ./tools/mk/Makefile.nginx.targ
include ./deps/eng/tools/mk/Makefile.targ
