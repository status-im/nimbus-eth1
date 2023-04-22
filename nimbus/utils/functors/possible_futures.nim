import
  chronos,
  options,
  ./identity,
  ./futures

# This file contains some operations that can work on either
# Identity or Future.

proc createPure*[V](v: V, c: var Identity[V]) {.inline.} = c = pureIdentity(v)
proc createPure*[V](v: V, c: var   Future[V]) {.inline.} = c = pureFuture(v)


proc toFuture*[V](i: Identity[V]): Future[V] = pureFuture(valueOf(i))
proc toFuture*[V](f:   Future[V]): Future[V] = f


proc waitForValueOf*[V](i: Identity[V]): V = valueOf(i)
proc waitForValueOf*[V](f:   Future[V]): V = waitFor(f)


proc maybeAlreadyAvailableValueOf*[V](i: Identity[V]): Option[V] =
  some(valueOf(i))

proc maybeAlreadyAvailableValueOf*[V](f: Future[V]): Option[V] =
  if f.completed:
    some(f.read)
  else:
    none[V]()


proc unsafeGetAlreadyAvailableValue*[V](c: Identity[V] | Future[V]): V =
  try:
    return maybeAlreadyAvailableValueOf(c).get
  except:
    doAssert(false, "Assertion failure: unsafeGetAlreadyAvailableValue called but the value is not yet available.")
