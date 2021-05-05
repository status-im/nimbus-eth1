# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
## Compile Time Switches For Conditional Compilation
## =================================================
##
## Depending on NIM command line switches `-d:evmc_enabled`,
## `-d:evmc2_enabled`, and `-d:vm2_enabled`, a set of mutually exclusive
## boolean constants is compiled
##
## * vm#_enabled => implementation in folder vm (# == 0) or vm#
## * evmc#_enabled => implementation in folder vm/vm# for evmc
##
## and an additional boolean constant is provided
##
## * evmc_enabled => `true` some evmc#_enabled is `true`
##

const
  # mutually exclusive <*_enabled> flags
  evmc2_enabled* = defined(evmc2_enabled)
  vm2_enabled* = defined(vm2_enabled) and not evmc2_enabled

  vm2_activated* =              ## set if either VM2 variant is activated
    vm2_enabled or evmc2_enabled

  evmc0_enabled* = defined(evmc_enabled) and not  vm2_activated
  vm0_enabled* = not evmc0_enabled and not vm2_activated

  vm0_activated* =              ## set if either naitve VM variant is activated
    vm0_enabled or evmc0_enabled


  evmc_enabled* =               ## set if either evmc is activated
    defined(evmc_enabled) or defined(evmc2_enabled)

  relay_exception_base_class* = ## map selected Exception tyype exceptions to
                                ## Defect to get them out of the way of
                                ## static raise[] annotation exception
                                ## analysis
    defined(vm2_debug)

  low_memory_compile_time* =    ## help with low memory when compiling
                                ## interpreter_dispatch.selectVM() function
    defined(vm2_lowmem)

static:
  doAssert vm2_activated or vm0_activated

# End
