import
  chronos

export chronos

# FIXME-Adam: These are a bunch of operations on Futures that I figure
# should exist somewhere in the chronos library, except that I couldn't
# find them. Are they in there somewhere? Can I add them?

proc pureFuture*[V](value: V): Future[V] =
  var fut = newFuture[V]("pureFuture")
  fut.complete(value)
  fut



proc discardFutureValue*[A](fut: Future[A]): Future[void] {.async.} =
  discard await fut

proc map*[A, B](futA: Future[A], callback: (proc(a: A): B {.gcsafe.})): Future[B] {.async.} =
  return callback(await futA)

proc flatMap*[A, B](futA: Future[A], callback: (proc(a: A): Future[B] {.gcsafe.})): Future[B] {.async.} =
  return await callback(await futA)

# FIXME-Adam: can I do some type magic to handle tuples of any length?
proc combine*[A, B](fA: Future[A], fB: Future[B]): Future[(A, B)] {.async.} =
  return (await fA, await fB)

proc combine*[A, B, C](fA: Future[A], fB: Future[B], fC: Future[C]): Future[(A, B, C)] {.async.} =
  return (await fA, await fB, await fC)

proc combine*[A, B, C, D](fA: Future[A], fB: Future[B], fC: Future[C], fD: Future[D]): Future[(A, B, C, D)] {.async.} =
  return (await fA, await fB, await fC, await fD)

proc combine*[A, B, C, D, E](fA: Future[A], fB: Future[B], fC: Future[C], fD: Future[D], fE: Future[E]): Future[(A, B, C, D, E)] {.async.} =
  return (await fA, await fB, await fC, await fD, await fE)

proc combine*[A, B, C, D, E, F](fA: Future[A], fB: Future[B], fC: Future[C], fD: Future[D], fE: Future[E], fF: Future[F]): Future[(A, B, C, D, E, F)] {.async.} =
  return (await fA, await fB, await fC, await fD, await fE, await fF)

proc combine*[A, B, C, D, E, F, G](fA: Future[A], fB: Future[B], fC: Future[C], fD: Future[D], fE: Future[E], fF: Future[F], fG: Future[G]): Future[(A, B, C, D, E, F, G)] {.async.} =
  return (await fA, await fB, await fC, await fD, await fE, await fF, await fG)

proc combineAndApply*[A, B, R](fA: Future[A], fB: Future[B], f: (proc(a: A, b: B): R {.gcsafe.})): Future[R] {.async.} =
  return f(await fA, await fB)

proc combineAndApply*[A, B, C, R](fA: Future[A], fB: Future[B], fC: Future[C], f: (proc(a: A, b: B, c: C): R {.gcsafe.})): Future[R] {.async.} =
  return f(await fA, await fB, await fC)

proc combineAndApply*[A, B, C, D, R](fA: Future[A], fB: Future[B], fC: Future[C], fD: Future[D], f: (proc(a: A, b: B, c: C, d: D): R {.gcsafe.})): Future[R] {.async.} =
  return f(await fA, await fB, await fC, await fD)

# FIXME-Adam: ugh, need to just implement all of this once
proc combineAndApply*[A, B, R](futs: (Future[A], Future[B]), f: (proc(a: A, b: B): R {.gcsafe.})): Future[R] =
  let (fA, fB) = futs
  combineAndApply(fA, fB, f)

proc combineAndApply*[A, B, C, R](futs: (Future[A], Future[B], Future[C]), f: (proc(a: A, b: B, c: C): R {.gcsafe.})): Future[R] =
  let (fA, fB, fC) = futs
  combineAndApply(fA, fB, fC, f)

proc combineAndApply*[A, B, C, D, R](futs: (Future[A], Future[B], Future[C], Future[D]), f: (proc(a: A, b: B, c: C, d: D): R {.gcsafe.})): Future[R] =
  let (fA, fB, fC, fD) = futs
  combineAndApply(fA, fB, fC, fD, f)

proc traverse*[A](futs: seq[Future[A]]): Future[seq[A]] {.async.} =
  var values: seq[A] = @[]
  for fut in futs:
    values.add(await fut)
  return values
