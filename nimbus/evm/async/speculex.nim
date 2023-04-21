import
  chronos,
  ../../utils/functors/possible_futures

# We could make this configurable in some way.
const shouldUseSpeculativeExecution* = true


# For now let's keep it possible to switch back at compile-time to
# having stack/memory/storage cells that are always a concrete value.

when shouldUseSpeculativeExecution:
  type SpeculativeExecutionCell*[V] = Future[V]
else:
  type SpeculativeExecutionCell*[V] = Identity[V]


# I'm disappointed that I can't do this and have the callers resolve
# properly based on the return type.
#[
proc pureCell*[V](v: V): Identity[V] {.inline.} =
  pureIdentity(v)

proc pureCell*[V](v: V): Future[V] {.inline.} =
  pureFuture(v)
]#

proc pureCell*[V](v: V): SpeculativeExecutionCell[V] {.inline.} =
  createPure(v, result)
