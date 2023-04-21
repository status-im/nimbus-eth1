import
  chronos

# This is simply a wrapper around a value. It should
# hopefully be zero-cost, since it's using 'distinct'.
# But I'm not sure whether it'll actually be zero-cost
# in situations (as I'm intending to use it) where
# it's used polymorphically from sites that could be
# an Identity or could be a Future.
# (See possible_futures.nim.)

type Identity*[Value] = distinct Value

proc pureIdentity*[V](value: V): Identity[V] {.inline.} =
  Identity(value)

proc valueOf*[V](i: Identity[V]): V {.inline.} =
  V(i)

proc map*[A, B](iA: Identity[A], callback: (proc(a: A): B {.gcsafe.})): Identity[B] {.inline.} =
  return Identity(callback(valueOf(iA)))

# FIXME-Adam: can I do some type magic to handle tuples of any length?
proc combine*[A, B](iA: Identity[A], iB: Identity[B]): Identity[(A, B)] =
  pureIdentity((valueOf(iA), valueOf(iB)))

proc combine*[A, B, C](iA: Identity[A], iB: Identity[B], iC: Identity[C]): Identity[(A, B, C)] =
  pureIdentity((valueOf(iA), valueOf(iB), valueOf(iC)))

proc combine*[A, B, C, D](iA: Identity[A], iB: Identity[B], iC: Identity[C], iD: Identity[D]): Identity[(A, B, C, D)] =
  pureIdentity((valueOf(iA), valueOf(iB), valueOf(iC), valueOf(iD)))

proc combine*[A, B, C, D, E](iA: Identity[A], iB: Identity[B], iC: Identity[C], iD: Identity[D], iE: Identity[E]): Identity[(A, B, C, D, E)] =
  pureIdentity((valueOf(iA), valueOf(iB), valueOf(iC), valueOf(iD), valueOf(iE)))

proc combine*[A, B, C, D, E, F](iA: Identity[A], iB: Identity[B], iC: Identity[C], iD: Identity[D], iE: Identity[E], iFF: Identity[F]): Identity[(A, B, C, D, E, F)] =
  pureIdentity((valueOf(iA), valueOf(iB), valueOf(iC), valueOf(iD), valueOf(iE), valueOf(iFF)))

proc combine*[A, B, C, D, E, F, G](iA: Identity[A], iB: Identity[B], iC: Identity[C], iD: Identity[D], iE: Identity[E], iFF: Identity[F], iG: Identity[G]): Identity[(A, B, C, D, E, F, G)] =
  pureIdentity((valueOf(iA), valueOf(iB), valueOf(iC), valueOf(iD), valueOf(iE), valueOf(iFF), valueOf(iG)))

proc combineAndApply*[A, B, R](iA: Identity[A], iB: Identity[B], f: (proc(a: A, b: B): R {.gcsafe.})): Identity[R] =
  pureIdentity(f(valueOf(iA), valueOf(iB)))

proc combineAndApply*[A, B, C, R](iA: Identity[A], iB: Identity[B], iC: Identity[C], f: (proc(a: A, b: B, c: C): R {.gcsafe.})): Identity[R] =
  pureIdentity(f(valueOf(iA), valueOf(iB), valueOf(iC)))

proc combineAndApply*[A, B, C, D, R](iA: Identity[A], iB: Identity[B], iC: Identity[C], iD: Identity[D], f: (proc(a: A, b: B, c: C, d: D): R {.gcsafe.})): Identity[R] =
  pureIdentity(f(valueOf(iA), valueOf(iB), valueOf(iC), valueOf(iD)))

# AARDVARK: ugh, need to just implement all of this once
proc combineAndApply*[A, B, R](idents: (Identity[A], Identity[B]), f: (proc(a: A, b: B): R {.gcsafe.})): Identity[R] =
  let (iA, iB) = idents
  combineAndApply(iA, iB, f)

proc combineAndApply*[A, B, C, R](idents: (Identity[A], Identity[B], Identity[C]), f: (proc(a: A, b: B, c: C): R {.gcsafe.})): Identity[R] =
  let (iA, iB, iC) = idents
  combineAndApply(iA, iB, iC, f)

proc combineAndApply*[A, B, C, D, R](idents: (Identity[A], Identity[B], Identity[C], Identity[D]), f: (proc(a: A, b: B, c: C, d: D): R {.gcsafe.})): Identity[R] =
  let (iA, iB, iC, iD) = idents
  combineAndApply(iA, iB, iC, iD, f)

proc traverse*[A](idents: seq[Identity[A]]): Identity[seq[A]] =
  var values: seq[A] = @[]
  for i in idents:
    values.add(valueOf(i))
  return pureIdentity(values)
