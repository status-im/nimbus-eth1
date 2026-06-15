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

{.push raises: [], gcsafe.}

template borrowRef*[T](dest, src: ref T) =
  # Copies the ref type without updating the ref count.
  copyMem(addr dest, addr src, sizeof(pointer))

template unborrowRef*[T](dest: ref T) =
  # Sets the ref type back to nil without updating the ref count.
  var p: pointer = nil
  copyMem(addr dest, addr p, sizeof(pointer))

# This SharedBytes type is needed in order to pass bytes (e.g. seq[byte]) between
# threads safely when using refc. The type is not designed to be thread safe.

type
  SharedBytes* = object
    data: ptr UncheckedArray[byte]
    len: int

proc init*(T: type SharedBytes, bytes: openArray[byte]): T =
  if bytes.len() == 0:
    return T()

  let sb = T(
    data: cast[ptr UncheckedArray[byte]](allocShared(bytes.len())),
    len: bytes.len()
  )  
  copyMem(sb.data, unsafeAddr bytes[0], bytes.len())

  sb

proc dispose*(sb: var SharedBytes) =
  if not sb.data.isNil():
    deallocShared(sb.data)
    sb.data = nil
    sb.len = 0

proc `=copy`*(
    dest: var SharedBytes, src: SharedBytes
) {.error: "Copying SharedBytes is forbidden".} =
  # Only a single owner is supported for now.
  discard

template toOpenArray(sb: SharedBytes): openArray[byte] =
  sb.data.toOpenArray(0, sb.len - 1)

func toSeq(sb: SharedBytes): seq[byte] =
  if sb.len == 0:
    return default(seq[byte])

  let s = newSeq[byte](sb.len)
  copyMem(addr s[0], sb.data, sb.len)
  s

template data*(sb: SharedBytes, asOpenArray: static bool = false): auto =
  when asOpenArray:
    sb.toOpenArray()
  else:
    sb.toSeq()
