#! /usr/bin/make -f

SAVED_PATH := $(PATH)
PWD        := $(shell pwd)

# Collect document names
SFX_FILTER := sed -e 's|^\./||;/\/\./d;/^docs\//d;s/\.[a-z]*$$//'
PNG_FILES  := $(shell find . -name '*.png' -print|$(SFX_FILTER))
MD_FILES   := $(shell find . -name '*.md'  -print|$(SFX_FILTER))
EXE_FILES  := $(shell find . -name '*.nim' -print|$(SFX_FILTER))

# Needed for the NIM compiler that comes with this repo
NIMBLE_DIR := $(dir $(PWD))/vendor/.nimble
NIM_PATH   := $(dir $(PWD))/vendor/nimbus-build-system/vendor/Nim/bin

# Support for verbosity: V=1
ifeq ($(V),1)
MUFFLE     :=
else
MUFFLE     := 2>/dev/null
endif

# Support for external NIM compiler unless X=0
ifneq ($(X),0)
# works with external nim 1.5.1 (not the local 1.2.10 one)
PATH       := $(SAVED_PATH):$(NIM_PATH):$(NIMBLE_DIR)/bin
else
PATH       := $(NIM_PATH):$(NIMBLE_DIR)/bin:$(SAVED_PATH)
endif

# Compat version is used with external NIM compiler
NIM_COMPAT := --useVersion:1.2

# Name of NIM compiler, test for newer version on host OS
NIM_CMD    := nim
NIM_TEST   := $(NIM_CMD) $(NIM_COMPAT) --help >/dev/null 2>&1
NIM_SELECT := $(NIM_TEST) && echo "$(NIM_CMD) $(NIM_COMPAT)"|| echo "$(NIM_CMD)"
# Note that the back ticks are needed in the following assignment
NIM_EXE    := `$(NIM_SELECT)`

# Markdown compiler (test for discount tool with tables support)
MD_CMD     := markdown
MD_TEST    := $(MD_CMD) -VV 2>/dev/null|grep -q TABLES

# Default target
default: help

# ------------------------------------------------------------------------------
# Help page
# ------------------------------------------------------------------------------

.SILENT: help
help::
	echo "Usage: $(MAKE) <target> [<option> ..]"
	echo
	echo "<option>: V=1          -- verbose mode"
	echo "          X=0          -- preferring local nim compiler (this repo)"
	echo
	echo "<target>: docs         -- build NIM docs"
	echo "          docs-update  -- process missing doc pages"
	echo "          docs-index   -- index collected docs"
	echo
	echo "          clean        -- clean up generated and backup files (not docs)"
	echo "          clean-exe    -- clean up generated executables"
	echo "          clean-docs   -- clean up generated docs and extra files"
	echo
	echo "          distclean    -- purge unnecessary stuff including docs"
	echo "          clobber      -- same as distclean"
	echo

# ------------------------------------------------------------------------------
# Build indexed dox
# ------------------------------------------------------------------------------

# Automatc rule for updating single html/idx file
docs/%.html : %.nim
#	use compat option if it works with the nim compiler
	@mkdir -p docs
	@nim=$(NIM_EXE); \
	(set -x; $$nim doc --outdir:docs --docRoot:$(PWD) --index:on \
		--errorMax:0 --verbosity:0 --hints:off --warnings:off \
		"$<" $(MUFFLE)) || true

# Automatc rule for updating markdown files
docs/ex/%.html : %.md
	@mkdir -p $(dir $@)
	@if $(MD_TEST); then \
	  (set -x; $(MD_CMD) "$<"); \
	else \
	  (echo "<pre>";(set -x;cat "$<");echo "</pre>"); \
	fi > "$@"

# Automatc rule for collecting raw files
docs/ex/%.png : %.png
	@mkdir -p $(dir $@)
	@set -x; cp "$<" "$@"


.PHONY: docs-index-helper
.SILENT: docs-index-helper
docs-index-helper:
	nim=$(NIM_EXE); \
	$$nim --version | sed q ; set -x ;\
	$$nim --skipProjCfg buildIndex -o:docs/theindex.html \
		--verbosity:0 --hints:off --warnings:off docs

.PHONY: docs-update-helper
.SILENT: docs-update-helper
docs-update-helper::
	$(NIM_EXE) --version | sed q

docs-update-helper:: $(foreach f,$(EXE_FILES),docs/$f.html)

# Kludge: some docs would only compile with the local NIM compiler
ifneq ($(X),0)
docs-update-helper::
	$(MAKE) docs-update-helper X=0 V=$(V)
endif


.PHONY: docs-extra-helper
.SILENT: docs-extra-helper
docs-extra-helper::
	$(MD_TEST) || ( \
	  echo ;\
	  echo "*** Discount markdown command with table processing is unavailable." ;\
	  echo "    On Debian/Ubuntu it is installed via \"apt install discount\".";\
	  echo "    So \"make\" is going to fall back to text file wrapping which can" ;\
	  echo "    be changed by passing \"MD_TEST=true\" to the \"make\" command line." ;\
	  echo ;\
	)

docs-extra-helper:: $(foreach f,$(MD_FILES),docs/ex/$f.html)
docs-extra-helper:: $(foreach f,$(PNG_FILES),docs/ex/$f.png)


.PHONY:  docs-update
.SILENT: docs-update
docs-update:: docs-update-helper
docs-update:: docs-extra-helper

.PHONY:  docs-index
.SILENT: docs-index
docs-index:: docs-index-helper

.PHONY:  docs
.SILENT: docs
docs:: docs-update
docs:: docs-index

# ------------------------------------------------------------------------------
# Clean up etc.
# ------------------------------------------------------------------------------

.PHONY: clobber distclean clean clean-exe clean-docs

.SILENT: clean-exe
clean-exe:
	for f in $(EXE_FILES); do \
	  [ -f "$$f" ] || continue ;\
	  (set -x; rm -f "$$f"); \
	done

.SILENT: clean-docs
clean-docs:
	for f in docs/dochack.js docs/nimdoc.out.css; do \
	  [ ! -f "$$f" ] || (set -x; rm -f "$$f"); \
	done
	for f in $(foreach f,$(EXE_FILES),docs/$f) \
	         $(foreach f,$(PNG_FILES),docs/ex/$f) \
	         $(foreach f,$(MD_FILES),docs/ex/$f) \
		 docs/nimdoc.out docs/vm/nimdoc.out docs/theindex; \
	do \
	  [ ! -f "$$f.html" ] || (set -x; rm -f "$$f.html"); \
	  [ ! -f "$$f.idx"  ] || (set -x; rm -f "$$f.idx"); \
	  [ ! -f "$$f.css"  ] || (set -x; rm -f "$$f.css"); \
	  [ ! -f "$$f.png"  ] || (set -x; rm -f "$$f.png"); \
	done
	for d in $(shell find docs -depth -type d -print $(MUFFLE)); do \
	  (set -x; rmdir "$$d" $(MUFFLE)) || true; \
	done

.SILENT: clean-bakfiles
clean-bakfiles:
	for f in $(shell find . -type f \
		-name '*~' -o -name '*.bak' -print); do \
	  (set -x; rm -f "$$f"); \
	done

.SILENT: clean-nimcache
clean-nimcache:
	[ ! -d ./nimcache ] || (set -x; rm -rf ./nimcache)

clean:: clean-exe
clean:: clean-bakfiles
clean:: clean-nimcache

distclean:: clean
distclean:: clean-docs

clobber:: distclean

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
