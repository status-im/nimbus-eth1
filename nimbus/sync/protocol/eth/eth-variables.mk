# Copyright (c) 2024 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# GNU-Makefile include
#
# When running make, the instructions here will define the variable
# "NIM_ETH_PARAMS" which should be appended to the nim compiler options.
#
# This makefile snippet supports multi-protocol arguments as in
# "ENABLE_ETH_VERSION=66:67:999" where available protocol versions are
# extracted and processed. In this case, protocol version 999 will be
# silently ignored.

# default wire protocol, triggered by empty/unset variable or zero value
ifeq ($(if $(ENABLE_ETH_VERSION),$(ENABLE_ETH_VERSION),0),0)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:eth67_enabled
endif

# parse list for supported items
ifneq ($(findstring :66:,:$(ENABLE_ETH_VERSION):),)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:eth66_enabled
endif

ifneq ($(findstring :67:,:$(ENABLE_ETH_VERSION):),)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:eth67_enabled
endif

ifneq ($(findstring :68:,:$(ENABLE_ETH_VERSION):),)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:eth68_enabled
endif

# There must be at least one protocol version.
ifeq ($(NIM_ETH_PARAMS),)
$(error Unacceptable protocol versions in "ENABLE_ETH_VERSION=$(ENABLE_ETH_VERSION)")
endif

# ------------

# chunked messages enabled by default, use ENABLE_CHUNKED_RLPX=0 to disable
ifneq ($(if $(ENABLE_CHUNKED_RLPX),$(ENABLE_CHUNKED_RLPX),1),0)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:chunked_rlpx_enabled
endif

# End
