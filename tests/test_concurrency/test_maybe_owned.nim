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

import unittest2, ../../execution_chain/concurrency/maybe_owned

proc getRefcount(p: pointer): int {.importc: "getRefcount".}

template rc(x: ref): int =
  getRefcount(cast[pointer](x))

type
  Payload = object
    value: int
    text: string

  Container = ref object
    inner: MaybeOwned[ref Payload]

proc newPayload(value: int): ref Payload =
  result = (ref Payload)(value: value)

suite "MaybeOwned Tests":

  test "default value is nil and not owned":
    var r: MaybeOwned[ref Payload]
    check:
      r.get().isNil()
      not r.isOwned()

  test "own returns the target and marks it owned":
    let src = newPayload(42)
    var r: MaybeOwned[ref Payload]
    r.own(src)
    check:
      cast[pointer](r.get()) == cast[pointer](src)
      r.get().value == 42
      r.isOwned()

  test "borrow returns the target and does not mark it owned":
    let src = newPayload(7)
    var r: MaybeOwned[ref Payload]
    r.borrow(src)
    check:
      cast[pointer](r.get()) == cast[pointer](src)
      r.get().value == 7
      not r.isOwned()

  test "mutations through a borrowed ref are visible via the source":
    let src = newPayload(1)
    let container = Container()
    container.inner.borrow(src)
    container.inner.get().value = 99
    container.inner.get().text = "mutated"
    check:
      src.value == 99
      src.text == "mutated"

  test "owning in a heap field increments the refcount":
    let src = newPayload(1)
    let before = rc(src)
    let container = Container()
    container.inner.own(src)
    check rc(src) == before + 1

    container.inner.own(nil)
    check rc(src) == before

  test "borrowing in a heap field does not change the refcount":
    let src = newPayload(1)
    let before = rc(src)
    let container = Container()
    container.inner.borrow(src)
    check rc(src) == before

    container.inner.borrow(nil)
    check rc(src) == before

  test "switching from owned to borrowed releases the reference":
    let src = newPayload(1)
    let before = rc(src)
    let container = Container()
    container.inner.own(src)
    check rc(src) == before + 1

    container.inner.borrow(src)
    check:
      rc(src) == before
      cast[pointer](container.inner.get()) == cast[pointer](src)
      not container.inner.isOwned()

  test "repeated borrows of different targets leave refcounts unchanged":
    let
      srcA = newPayload(1)
      srcB = newPayload(2)
      beforeA = rc(srcA)
      beforeB = rc(srcB)
      container = Container()
    for i in 0 ..< 16:
      container.inner.borrow(if i mod 2 == 0: srcA else: srcB)
      check container.inner.get().value == (if i mod 2 == 0: 1 else: 2)
    check:
      rc(srcA) == beforeA
      rc(srcB) == beforeB
