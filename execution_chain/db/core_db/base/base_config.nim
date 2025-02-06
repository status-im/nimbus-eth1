# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

# Configuration section
const
  EnableApiTracking = false
    ## When enabled, functions using this tracking facility need to import
    ## `chronicles`, as well. Also, some `func` designators might need to
    ## be changed to `proc` for possible side effects.
    ##
    ## Tracking noise is then enabled by setting the flag `trackCoreDbApi` to
    ## `true` in the `CoreDbRef` descriptor.

  AutoValidateDescriptors = defined(release).not or
                            defined(unittest2DisableParamFiltering)
    ## No validatinon needed for production suite.
    ##
    ## The `unittest2DisableParamFiltering` flag is coincidentally used by
    ## unit/integration tests which makes it convenient to piggyback on that
    ## for enabling debugging checks.

  EnableApiJumpTable = defined(dbjapi_enabled) or
                       defined(unittest2DisableParamFiltering)
    ## This flag enables the functions jump table even if `EnableApiProfiling`
    ## and `EnableCaptJournal` is set `false` in realease mode. This setting
    ## should be used for debugging, only.
    ##
    ## The `unittest2DisableParamFiltering` flag is coincidentally used by
    ## unit/integration tests which makes it convenient to piggyback on that
    ## for providing API jump tables.

  EnableProfiling = false
    ## Enables profiling of the backend if the flags ` EnableApiJumpTable`
    ## and `EnableApiTracking` are also set. Profiling will then be enabled
    ## with the flag `trackCoreDbApi` (which also enables extra logging.)

  EnableCaptJournal = true
    ## Enables the tracer facility if the flag ` EnableApiJumpTable` is
    ## also set. In that case the capture journal directives like
    ## `newCapture()` will be available.

  NoisyCaptJournal = true
    ## Provide extra logging with the tracer facility if available.


# Exportable constants (leave alone this section)
const
  CoreDbEnableApiTracking* = EnableApiTracking

  CoreDbAutoValidateDescriptors* = AutoValidateDescriptors

  # Api jump table dependent settings:

  CoreDbEnableApiJumpTable* = EnableApiJumpTable

  CoreDbEnableProfiling* = EnableProfiling and CoreDbEnableApiJumpTable

  CoreDbEnableCaptJournal* = EnableCaptJournal and CoreDbEnableApiJumpTable

  CoreDbNoisyCaptJournal* = NoisyCaptJournal and CoreDbEnableCaptJournal


# Support warning about extra compile time options. For production, non of
# the above features should be enabled.
import strutils
const coreDbBaseConfigExtras* = block:
  var s: seq[string]
  when CoreDbEnableApiTracking:
    s.add "logging"
  when CoreDbAutoValidateDescriptors:
    s.add "validate"
  when CoreDbEnableProfiling:
    s.add "profiling"
  when CoreDbEnableCaptJournal:
    when CoreDbNoisyCaptJournal:
      s.add "noisy tracer"
    else:
      s.add "tracer"
  when CoreDbEnableApiJumpTable and
       not CoreDbEnableProfiling and
       not CoreDbEnableCaptJournal:
    s.add "Api jump table"
  if s.len == 0:
    ""
  else:
    "CoreDb(" & s.join(", ") & ")"

# End
