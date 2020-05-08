import random, sets, nimcrypto/sysrand

type
  RandGen*[T] = object
    minVal, maxVal: T

  Bytes* = seq[byte]

proc rng*[T](minVal, maxVal: T): RandGen[T] =
  doAssert(minVal <= maxVal)
  result.minVal = minVal
  result.maxVal = maxVal

proc rng*[T](minMax: T): RandGen[T] =
  rng(minMax, minMax)

proc getVal*[T](x: RandGen[T]): T =
  if x.minVal == x.maxVal: return x.minVal
  rand(x.minVal..x.maxVal)

proc randString*(len: int): string =
  result = newString(len)
  discard randomBytes(result[0].addr, len)

proc randBytes*(len: int): Bytes =
  result = newSeq[byte](len)
  discard randomBytes(result[0].addr, len)

proc randPrimitives*[T](val: int): T =
  type
    ByteLike = uint8 | byte | char

  when T is string:
    randString(val)
  elif T is int:
    result = val
  elif T is ByteLike:
    result = T(val)
  elif T is Bytes:
    result = randBytes(val)

proc randList*(T: typedesc, fillGen: RandGen, listLen: int, unique: static[bool] = true): seq[T] =
  result = newSeqOfCap[T](listLen)
  when unique:
    var set = initHashSet[T]()
    for len in 0..<listLen:
      while true:
        let x = randPrimitives[T](fillGen.getVal())
        if x notin set:
          result.add x
          set.incl x
          break
  else:
    for len in 0..<listLen:
      let x = randPrimitives[T](fillGen.getVal())
      result.add x

proc randList*(T: typedesc, fillGen, listGen: RandGen, unique: static[bool] = true): seq[T] =
  randList(T, fillGen, listGen.getVal(), unique)
