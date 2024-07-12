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

  EnableProfiling = false
    ## Enables profiling of the backend. If the flag `EnableApiTracking` is
    ## also set the API will also be subject to profiling.

  EnableCaptJournal = defined(release).not
    ## Enables the tracer facility. If set `true` capture journal directives
    ## like `newCapture()` will be available.
  
  NoisyCaptJournal = true
    ## Provide extra logging with the tracer facility if available.
  
  EnableApiJumpTable = false
    ## This flag enables the functions jump table even if `EnableApiProfiling`
    ## and `EnableCaptJournal` is set `false` in realease mode. This setting
    ## should be used for debugging, only.

  AutoValidateDescriptors = defined(release).not
    ## No validatinon needed for production suite.

# Exportable constants (leave alone this section)
const
  CoreDbEnableApiTracking* = EnableApiTracking

  CoreDbEnableProfiling* = EnableProfiling

  CoreDbEnableCaptJournal* = EnableCaptJournal

  CoreDbNoisyCaptJournal* = CoreDbEnableCaptJournal and NoisyCaptJournal

  CoreDbEnableApiJumpTable* =
    CoreDbEnableProfiling or CoreDbEnableCaptJournal or EnableApiJumpTable

  CoreDbAutoValidateDescriptors* = AutoValidateDescriptors

# End
