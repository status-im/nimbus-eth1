# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# These borrow functions are a workaround to avoid updating the ref count
# of a ref type when assigning it into another ref type or heap object.
# This is needed because refc doesn't support atomic reference counts
# and when passing in a ref type from the main thread as a parameter
# of a new ref instance in a child thread/task the ref count update can cause
# memory corruption and crashes due to a race with the ref counts being updated
# in both the main thread and the child thread concurrently.
#
# The unborrowRef function is needed to cleanup the borrowed ref after usage
# and before the GC runs on the ref type containing the borrowed ref.

template borrowRef*[T](dest, src: ref T) =
  # Copies the ref type without updating the ref count.
  copyMem(addr dest, addr src, sizeof(pointer))

template unborrowRef*[T](dest: ref T) =
  # Sets the ref type back to nil without updating the ref count.
  var p: pointer = nil
  copyMem(addr dest, addr p, sizeof(pointer))