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

import unittest2, ../../execution_chain/concurrency/utils

proc getRefcount(p: pointer): int {.importc: "getRefcount".}

template rc(x: ref): int =
  getRefcount(cast[pointer](x))

type
  Payload = object
    value: int
    text: string

  Container = ref object
    inner: ref Payload

suite "Concurrency Utils Tests":

  test "borrowRef copies the pointer to the destination":
    var src: ref Payload
    new(src)
    src.value = 42
    src.text = "hello"

    var dest: ref Payload
    dest.borrowRef(src)

    check:
      dest != nil
      cast[pointer](dest) == cast[pointer](src)
      dest.value == 42
      dest.text == "hello"

    dest.unborrowRef()

  test "unborrowRef clears the destination back to nil":
    var src: ref Payload
    new(src)
    src.value = 7

    var dest: ref Payload
    dest.borrowRef(src)
    check dest != nil

    dest.unborrowRef()
    check:
      dest == nil
      src != nil
      src.value == 7

  test "mutations through borrowed ref are visible via source":
    var src: ref Payload
    new(src)
    src.value = 1

    var dest: ref Payload
    dest.borrowRef(src)
    dest.value = 99
    dest.text = "mutated"

    check:
      src.value == 99
      src.text == "mutated"

    dest.unborrowRef()

  test "borrowRef into a field of a heap-allocated object":
    var src: ref Payload
    new(src)
    src.value = 555

    let container = Container()
    container.inner.borrowRef(src)

    check:
      container.inner != nil
      cast[pointer](container.inner) == cast[pointer](src)
      container.inner.value == 555

    container.inner.unborrowRef()
    check container.inner == nil

  test "repeated borrow and unborrow cycles":
    var src: ref Payload
    new(src)
    src.value = 10

    var dest: ref Payload
    for i in 0 ..< 16:
      dest.borrowRef(src)
      check:
        dest != nil
        dest.value == 10
      dest.unborrowRef()
      check dest == nil

    check:
      src != nil
      src.value == 10

  test "rebinding a borrowed ref to a different source":
    var srcA, srcB: ref Payload
    new(srcA)
    new(srcB)
    srcA.value = 1
    srcB.value = 2

    var dest: ref Payload
    dest.borrowRef(srcA)
    check cast[pointer](dest) == cast[pointer](srcA)

    dest.unborrowRef()
    dest.borrowRef(srcB)
    check:
      cast[pointer](dest) == cast[pointer](srcB)
      dest.value == 2

    dest.unborrowRef()

  test "borrowRef does not change the source refcount":
    var src: ref Payload
    new(src)
    let before = rc(src)

    var dest: ref Payload
    dest.borrowRef(src)
    check:
      rc(src) == before
      rc(dest) == before

    dest.unborrowRef()

  test "unborrowRef does not change the source refcount":
    var src: ref Payload
    new(src)
    let before = rc(src)

    var dest: ref Payload
    dest.borrowRef(src)
    dest.unborrowRef()

    check rc(src) == before

  test "normal ref assignment to a heap field bumps the refcount (control)":
    var src: ref Payload
    new(src)
    let before = rc(src)

    let container = Container()
    container.inner = src
    check rc(src) == before + 1

    container.inner = nil
    check rc(src) == before

  test "borrowRef into a heap field does not change the source refcount":
    var src: ref Payload
    new(src)
    let before = rc(src)

    let container = Container()
    container.inner.borrowRef(src)
    check:
      rc(src) == before
      rc(container.inner) == before

    container.inner.unborrowRef()
    check rc(src) == before

  test "repeated borrow/unborrow cycles leave the refcount unchanged":
    var src: ref Payload
    new(src)
    let before = rc(src)

    var dest: ref Payload
    for i in 0 ..< 16:
      dest.borrowRef(src)
      check rc(src) == before
      dest.unborrowRef()
      check rc(src) == before

