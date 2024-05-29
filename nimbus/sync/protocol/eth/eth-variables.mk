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

# chunked messages enabled by default, use ENABLE_CHUNKED_RLPX=0 to disable
ifneq ($(if $(ENABLE_CHUNKED_RLPX),$(ENABLE_CHUNKED_RLPX),1),0)
NIM_ETH_PARAMS := $(NIM_ETH_PARAMS) -d:chunked_rlpx_enabled
endif

# End
