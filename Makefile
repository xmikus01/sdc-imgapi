#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2016 Joyent, Inc.
#

#
# Makefile for IMGAPI
#

#
# Vars, Tools, Files, Flags
#
NAME		:= imgapi

DOC_FILES	 = index.md operator-guide.md
EXTRA_DOC_DEPS += deps/restdown-brand-remora/.git
RESTDOWN_FLAGS   = --brand-dir=deps/restdown-brand-remora

JS_FILES	:= $(shell ls *.js) \
	$(shell find lib test -name '*.js' | grep -v '/tmp/') \
	bin/imgapi-external-manta-setup \
	bin/imgapi-manta-setup
JSL_CONF_NODE	 = tools/jsl.node.conf
JSL_FILES_NODE	 = $(JS_FILES)
JSSTYLE_FILES	 = $(JS_FILES)
JSSTYLE_FLAGS	 = -f tools/jsstyle.conf
SMF_MANIFESTS = $(shell ls smf/manifests/*.xml)
NODEUNIT	:= ./node_modules/.bin/nodeunit
CLEAN_FILES += ./node_modules

NODE_PREBUILT_VERSION=v4.8.4
ifeq ($(shell uname -s),SunOS)
	NODE_PREBUILT_TAG=zone
	# Allow building on other than image sdc-minimal-multiarch-lts@15.4.1.
	NODE_PREBUILT_IMAGE=18b094b0-eb01-11e5-80c1-175dac7ddf02
endif


include ./tools/mk/Makefile.defs
ifeq ($(shell uname -s),SunOS)
	include ./tools/mk/Makefile.node_prebuilt.defs
else
	NPM=npm
	NODE=node
	NPM_EXEC=$(shell which npm)
	NODE_EXEC=$(shell which node)
endif
include ./tools/mk/Makefile.smf.defs

RELEASE_TARBALL	:= $(NAME)-pkg-$(STAMP).tar.bz2
RELSTAGEDIR       := /tmp/$(STAMP)



#
# Targets
#
.PHONY: all
all: $(SMF_MANIFESTS) docs | $(NPM_EXEC) $(REPO_DEPS) sdc-scripts
	$(NPM) install

$(NODEUNIT) node_modules/restify: | $(NPM_EXEC)
	$(NPM) install

.PHONY: test
test: | $(NODEUNIT)
	echo "error: standalone test suite is currently broken"
	exit 1
	#./test/runtests -lp  # test local 'public' mode
	#./test/runtests -l   # test local 'dc' mode

# We get the IMGAPI errors table from "lib/errors.js". This should be re-run
# for "lib/errors.js" changes!
.PHONY: doc-update-error-table
doc-update-error-table: lib/errors.js | node_modules/restify $(NODE_EXEC)
	$(NODE) lib/errors.js > build/errors.md
	$(NODE) -e ' \
	    fs = require("fs"); \
	    enc = {encoding: "utf8"}; \
	    index = fs.readFileSync("docs/index.md", enc); \
	    errors = fs.readFileSync("build/errors.md", enc); \
	    start = "<!-- ERROR TABLE START -->\n"; \
	    end = "<!-- ERROR TABLE END -->\n"; \
	    startIdx = index.indexOf(start); \
	    if (startIdx === -1) \
		throw new Error("cannot find start marker in build/errors.md"); \
	    endIdx = index.indexOf(end); \
	    if (endIdx === -1) \
		throw new Error("cannot find end marker in build/errors.md"); \
	    index = ( \
		index.slice(0, startIdx + start.length) \
		+ "\n" \
		+ errors \
		+ "\n" \
		+ index.slice(endIdx)); \
	    fs.writeFileSync("docs/index.md", index, enc);'
	@echo "'docs/index.md' updated"

DOC_CLEAN_FILES = docs/{index,operator-guide}.{html,json} \
	build/errors.md \
	build/docs
.PHONY: clean-docs
clean-docs:
	-$(RMTREE) $(DOC_CLEAN_FILES)
clean:: clean-docs

# See IMGAPI-445 for why this symlink.
build/docs/public/docs:
	mkdir -p build/docs/public
	(cd build/docs/public && rm -f docs && ln -s . docs)

docs:: build/docs/public/docs


.PHONY: release
release: all
	@echo "Building $(RELEASE_TARBALL)"
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)
	mkdir -p $(RELSTAGEDIR)/site
	touch $(RELSTAGEDIR)/site/.do-not-delete-me
	mkdir -p $(RELSTAGEDIR)/root
	cp -r \
		$(TOP)/bin \
		$(TOP)/main.js \
		$(TOP)/lib \
		$(TOP)/etc \
		$(TOP)/node_modules \
		$(TOP)/package.json \
		$(TOP)/sapi_manifests \
		$(TOP)/smf \
		$(TOP)/test \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/tools
	cp -r \
		$(TOP)/tools/standalone \
		$(TOP)/tools/seed-packages \
		$(TOP)/tools/prepare-image \
		$(TOP)/tools/get-image-dataset-guid.sh \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/tools/
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/boot
	cp -R $(TOP)/deps/sdc-scripts/* $(RELSTAGEDIR)/root/opt/smartdc/boot/
	cp -R $(TOP)/boot/* $(RELSTAGEDIR)/root/opt/smartdc/boot/
	mkdir -p $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build
	cp -PR \
		$(TOP)/build/node \
		$(TOP)/build/docs \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build
	# Trim node
	rm -rf \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build/node/bin/npm \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build/node/lib/node_modules \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build/node/include \
		$(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/build/node/share
	# Trim node_modules (this is death of a 1000 cuts, try for some
	# easy wins).
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name test | xargs -n1 rm -rf
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name tests | xargs -n1 rm -rf
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name examples | xargs -n1 rm -rf
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name "draft-*" | xargs -n1 rm -rf  # draft xml stuff in json-schema
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name libusdt | xargs -n1 rm -rf  # dtrace-provider
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name obj.target | xargs -n1 rm -rf  # dtrace-provider
	find $(RELSTAGEDIR)/root/opt/smartdc/$(NAME)/node_modules -name deps | grep 'extsprintf/deps$$' | xargs -n1 rm -rf  # old extsprintf shipped dev bits
	# Tar
	(cd $(RELSTAGEDIR) && $(TAR) -jcf $(TOP)/$(RELEASE_TARBALL) root site)
	@rm -rf $(RELSTAGEDIR)

.PHONY: publish
publish: release
	@if [[ -z "$(BITS_DIR)" ]]; then \
		@echo "error: 'BITS_DIR' must be set for 'publish' target"; \
		exit 1; \
	fi
	mkdir -p $(BITS_DIR)/$(NAME)
	cp $(TOP)/$(RELEASE_TARBALL) $(BITS_DIR)/$(NAME)/$(RELEASE_TARBALL)

.PHONY: devrun
devrun:
	node-dev main.js -f etc/imgapi.config.json | bunyan -o short

.PHONY: dumpvar
dumpvar:
	@if [[ -z "$(VAR)" ]]; then \
		echo "error: set 'VAR' to dump a var"; \
		exit 1; \
	fi
	@echo "$(VAR) is '$($(VAR))'"

include ./tools/mk/Makefile.deps
ifeq ($(shell uname -s),SunOS)
	include ./tools/mk/Makefile.node_prebuilt.targ
endif
include ./tools/mk/Makefile.smf.targ
include ./tools/mk/Makefile.targ

sdc-scripts: deps/sdc-scripts/.git
