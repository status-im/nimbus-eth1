# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Provision of `eth` versions list at compile time
##
## Note: This file allows read the `ethVersions` list at each level of the
##       source code import hierarchy. It needs to be *included* though if
##       `ethVersions` needs to be available at compile time (as of
##       NIM 1.6.18). This allows to construct directives like:
##       `when 66 in ethVersions: ..`
##

const
  buildEthVersions = block:
    var rc: seq[int]
    when defined(eth66_enabled): rc.add 66
    when defined(eth67_enabled): rc.add 67
    when defined(eth68_enabled): rc.add 68
    rc

# Default protocol only
when buildEthVersions.len == 0:
  const ethVersions* = @[67]
    ## Compile time list of available/supported eth versions
else:
  # One or more protocols
  const ethVersions* = buildEthVersions
    ## Compile time list of available/supported eth versions

# End
