# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Generic iterator, prototype to be included (rather than imported). Using
## an include file avoids duplicating code because the `T` argument is not
## bound to any object type. Otherwise all object types would be required
## when providing this iterator for import.
##
## This is not wanted here, because the import of a **pesistent** object
## would always require extra linking.

template valueOrApiError[U,V](rc: Result[U,V]; info: static[string]): U =
  rc.valueOr: raise (ref CoreDbApiError)(msg: info)

# ---------------

template kvt(dsc: CoreDbKvtRef): KvtDbRef =
  dsc.distinctBase.kvt

template call(api: KvtApiRef; fn: untyped; args: varArgs[untyped]): untyped =
  when CoreDbEnableApiJumpTable:
    api.fn(args)
  else:
    fn(args)

template call(kvt: CoreDbKvtRef; fn: untyped; args: varArgs[untyped]): untyped =
  kvt.distinctBase.parent.kvtApi.call(fn, args)

# ---------------
  
template mpt(dsc: CoreDbAccRef | CoreDbMptRef): AristoDbRef =
  dsc.distinctBase.mpt

template rootID(mpt: CoreDbMptRef): VertexID =
  VertexID(CtGeneric)

template call(api: AristoApiRef; fn: untyped; args: varArgs[untyped]): untyped =
  when CoreDbEnableApiJumpTable:
    api.fn(args)
  else:
    fn(args)

template call(
    acc: CoreDbAccRef | CoreDbMptRef;
    fn: untyped;
    args: varArgs[untyped];
      ): untyped =
  acc.distinctBase.parent.ariApi.call(fn, args)

# ---------------

iterator aristoReplicate[T](
    mpt: CoreDbMptRef;
      ): (Blob,Blob)
      {.gcsafe, raises: [CoreDbApiError].} =
  ## Generic iterator used for building dedicated backend iterators.
  ##
  let p = mpt.call(forkTx, mpt.mpt, 0).valueOrApiError "aristoReplicate()"
  defer: discard mpt.call(forget, p)
  for (vid,key,vtx,node) in T.replicate(p):
    if key.len == 32:
      yield (@(key.data), node.encode)
    elif vid == mpt.rootID:
      yield (@(key.to(Hash256).data), node.encode)

# End
