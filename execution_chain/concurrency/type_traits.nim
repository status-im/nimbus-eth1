# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [], gcsafe.}

import std/typetraits
from stew/shims/typetraits import supportsSharedMem

export supportsSharedMem

template withMutable*(val, v, body: untyped): untyped =
  ## Run `body` with `v` bound to a mutable handle on `val`, copying only when
  ## necessary: a copyable, addressable `val` is borrowed in place - consuming
  ## it (see `consume`) is a plain copy that leaves the source untouched - while
  ## a move-only or non-addressable `val` is captured into a local first.
  ##
  ## In the borrow case `val` is read only when it is consumed, so a `val` that
  ## aliases storage owned by the consuming container (e.g. a value borrowed
  ## from the very cache being written to) is not supported - copy such a value
  ## explicitly instead.
  block:
    when supportsCopyMem(typeof(val)) and compiles(unsafeAddr(val)):
      let vp = unsafeAddr(val)
      template v(): untyped =
        vp[]

      body
    else:
      var v = val
      body

template consume*[V](value: var V): untyped =
  ## Take ownership of `value`, leaving it spent.
  ##
  ## Containers that store a value should take it as `var` and consume it here
  ## rather than declare a `sink` parameter: for a V with no lifetime hooks the
  ## compiler passes a `sink` parameter by value, so every call frame the value
  ## crosses costs a full copy of it, while a `var` parameter is passed by
  ## reference. Such a V has nothing to release, so the consuming assignment is
  ## a plain copy; only a V with hooks needs the move.
  when supportsCopyMem(V):
    value
  else:
    move(value)
