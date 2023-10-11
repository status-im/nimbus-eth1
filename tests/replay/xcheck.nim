# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  unittest2

# ------------------------------------------------------------------------------
# Public workflow helpers
# ------------------------------------------------------------------------------

template xCheck*(expr: untyped): untyped =
  ## Note: this check will invoke `expr` twice
  if not (expr):
    check expr
    return

template xCheck*(expr: untyped; ifFalse: untyped): untyped =
  ## Note: this check will invoke `expr` twice
  if not (expr):
    ifFalse
    check expr
    return

template xCheckRc*(expr: untyped): untyped =
  if rc.isErr:
    xCheck(expr)

template xCheckRc*(expr: untyped; ifFalse: untyped): untyped =
  if rc.isErr:
    xCheck(expr, ifFalse)

template xCheckErr*(expr: untyped): untyped =
  if rc.isOk:
    xCheck(expr)

template xCheckErr*(expr: untyped; ifFalse: untyped): untyped =
  if rc.isOk:
    xCheck(expr, ifFalse)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
