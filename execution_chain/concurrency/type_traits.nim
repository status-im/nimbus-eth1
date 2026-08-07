# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [], gcsafe.}

import std/[macros, typetraits]

proc containsGcMem(t: NimNode, depth: int): bool

proc isTracedProc(procTy: NimNode): bool =
  const untracedConvs = [
    "nimcall", "cdecl", "stdcall", "safecall", "fastcall", "thiscall", "syscall",
    "noconv", "member",
  ]

  if procTy.kind == nnkProcTy and procTy.len > 1 and procTy[1].kind == nnkPragma:
    for pragma in procTy[1]:
      for conv in untracedConvs:
        if pragma.eqIdent(conv):
          return false
  true

proc walkFields(n: NimNode, depth: int): bool =
  case n.kind
  of nnkIdentDefs:
    containsGcMem(n[^2], depth + 1)
  of nnkOfInherit:
    containsGcMem(n[0], depth + 1)
  of nnkRecCase, nnkRecList, nnkOfBranch, nnkElse, nnkObjectTy, nnkTupleTy:
    for child in n:
      if walkFields(child, depth):
        return true
    false
  else:
    false

proc containsGcMem(t: NimNode, depth: int): bool =
  if depth > 64:
    error("type too deeply nested to check for garbage collected memory: " & t.repr)

  case t.kind
  of nnkRefTy:
    return true
  of nnkDistinctTy:
    return containsGcMem(t[0], depth + 1)
  of nnkObjectTy, nnkTupleTy:
    return walkFields(t, depth)
  of nnkTupleConstr, nnkPar:
    for child in t:
      if containsGcMem(child, depth + 1):
        return true
    return false
  of nnkProcTy:
    return isTracedProc(t)
  of nnkBracketExpr:
    if t[0].eqIdent("seq"):
      return true
    if t[0].eqIdent("array") or t[0].eqIdent("UncheckedArray"):
      return containsGcMem(t[^1], depth + 1)
    if t[0].eqIdent("set") or t[0].eqIdent("ptr"):
      return false
    return containsGcMem(t.getTypeImpl(), depth + 1)
  else:
    discard

  case t.typeKind
  of ntyString, ntySequence, ntyRef:
    true
  of ntyProc:
    isTracedProc(t.getTypeImpl())
  of ntyArray:
    containsGcMem(t.getTypeImpl()[^1], depth + 1)
  of ntyDistinct:
    containsGcMem(t.getTypeImpl()[0], depth + 1)
  of ntyObject, ntyTuple, ntyGenericInst, ntyAlias:
    containsGcMem(t.getTypeImpl(), depth + 1)
  else:
    false

macro supportsSharedMem*(T: typedesc): bool =
  newLit(not containsGcMem(T.getTypeInst()[1], 0))

template consume*[V](value: var V): untyped =
  ## Take ownership of `value`, leaving it spent.
  ##
  ## Containers that store a value should take it as `var` and consume it here
  ## rather than declare a `sink` parameter: for a V with no lifetime hooks the
  ## compiler passes a `sink` parameter by value, so every call frame the value
  ## crosses costs a full copy of it, while a `var` parameter is passed by
  ## reference. Such a V has nothing to release, so the consuming assignment is
  ## a plain copy; only a V with hooks needs the move.
  when supportsCopyMem(V):
    value
  else:
    move(value)
