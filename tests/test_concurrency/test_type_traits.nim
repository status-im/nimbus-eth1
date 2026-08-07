# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/typetraits,
  unittest2,
  results,
  eth/common/[addresses, headers],
  ../../execution_chain/concurrency/[shared_types, type_traits]

type
  Plain = object
    a: int
    b: array[4, byte]

  WithSeq = object
    a: int
    s: seq[byte]

  Nested = object
    inner: Plain

  NestedGc = object
    inner: WithSeq

  Variant = object
    case kind: bool
    of true: x: int
    of false: y: seq[byte]

  VariantPlain = object
    case kind: bool
    of true: x: int
    of false: y: array[8, byte]

  Base = object of RootObj
    a: int

  DerivedPlain = object of Base
    b: array[4, byte]

  DerivedGc = object of Base
    b: string

  DistinctPlain = distinct array[32, byte]
  DistinctGc = distinct seq[byte]

  WithClosure = object
    fn: proc(x: int)

  WithNimcall = object
    fn: proc(x: int) {.nimcall.}

  WithPtrToGc = object
    p: ptr string

  Box[T] = object
    v: T

  BoxRef[T] = ref object
    v: T

  VariantBox[T] = object
    case kind: bool
    of true: a: int
    of false: b: T

  ArrayAlias = array[16, byte]
  SeqAlias = seq[byte]

suite "supportsSharedMem Tests":
  test "plain non-GC types are accepted":
    check:
      supportsSharedMem(int)
      supportsSharedMem(byte)
      supportsSharedMem(array[32, byte])
      supportsSharedMem(Plain)
      supportsSharedMem(Nested)
      supportsSharedMem(VariantPlain)
      supportsSharedMem(DerivedPlain)
      supportsSharedMem(DistinctPlain)
      supportsSharedMem(ArrayAlias)
      supportsSharedMem(tuple[a: int, b: array[4, byte]])
      supportsSharedMem((int, uint16))
      supportsSharedMem((int, array[4, byte]))
      supportsSharedMem(Address)

  test "pointers and untraced proc types are accepted":
    check:
      supportsSharedMem(pointer)
      supportsSharedMem(cstring)
      supportsSharedMem(ptr UncheckedArray[byte])
      supportsSharedMem(WithPtrToGc)
      supportsSharedMem(WithNimcall)

  test "move-only types without GC memory are accepted":
    check:
      not supportsCopyMem(SharedBytes)
      supportsSharedMem(SharedBytes)

      not supportsCopyMem(SharedSeq[uint64])
      supportsSharedMem(SharedSeq[uint64])

      not supportsCopyMem(SharedTable[int, SharedBytes])
      supportsSharedMem(SharedTable[int, SharedBytes])

  test "GC managed types are rejected":
    check:
      not supportsSharedMem(string)
      not supportsSharedMem(seq[byte])
      not supportsSharedMem(SeqAlias)
      not supportsSharedMem(WithSeq)
      not supportsSharedMem(NestedGc)
      not supportsSharedMem(DerivedGc)
      not supportsSharedMem(DistinctGc)
      not supportsSharedMem(WithClosure)
      not supportsSharedMem(ref Plain)
      not supportsSharedMem(tuple[a: int, b: string])
      not supportsSharedMem((int, string))
      not supportsSharedMem((int, seq[byte]))
      not supportsSharedMem(Header)

  test "a variant branch holding GC memory is rejected":
    check:
      not supportsSharedMem(Variant)
      not supportsSharedMem(VariantBox[seq[byte]])
      supportsSharedMem(VariantBox[int])

  test "generic parameters are resolved before checking":
    check:
      supportsSharedMem(Box[int])
      supportsSharedMem(Box[SharedBytes])
      supportsSharedMem(array[4, Box[int]])
      supportsSharedMem(Opt[int])
      supportsSharedMem(Opt[SharedBytes])
      supportsSharedMem(Result[int, void])

      not supportsSharedMem(Box[seq[byte]])
      not supportsSharedMem(Box[Box[string]])
      not supportsSharedMem(BoxRef[int])
      not supportsSharedMem(array[4, Box[string]])
      not supportsSharedMem(Opt[seq[byte]])
      not supportsSharedMem(Result[int, string])
