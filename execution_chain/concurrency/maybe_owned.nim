# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

type
  MaybeOwned*[T: ref] = object
    ## A ref that is either owned, like a normal ref field, or borrowed as a
    ## raw pointer that refc neither reference counts nor traces. Worker
    ## threads borrow the main thread's refs this way so that they never update
    ## its reference counts non-atomically and their cycle collector never
    ## walks the main thread's heap. A borrowed target must outlive the holder.
    owner: T
    raw: pointer

func get*[T](r: MaybeOwned[T]): T {.inline.} =
  cast[T](r.raw)

func isOwned*[T](r: MaybeOwned[T]): bool =
  not r.owner.isNil()

func own*[T](r: var MaybeOwned[T], value: T) =
  r.owner = value
  r.raw = cast[pointer](value)

func borrow*[T](r: var MaybeOwned[T], value: T) =
  r.owner = nil
  r.raw = cast[pointer](value)
