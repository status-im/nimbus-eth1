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
  rc.valueOr: raise (ref AristoApiRlpError)(msg: info)

iterator aristoReplicate[T](
    dsc: CoreDxMptRef;
      ): (Blob,Blob)
      {.gcsafe, raises: [AristoApiRlpError].} =
  ## Generic iterator used for building dedicated backend iterators.
  ##
  let
    root = dsc.rootID
    mpt = dsc.to(AristoDbRef)
    api = dsc.toAristoApi()
    p = api.forkTop(mpt).valueOrApiError "aristoReplicate()"
  defer: discard api.forget(p)
  for (vid,key,vtx,node) in T.replicate(p):
    if key.len == 32:
      yield (@key, node.encode)
    elif vid == root:
      yield (@(key.to(Hash256).data), node.encode)

# End
