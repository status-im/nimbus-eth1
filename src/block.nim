import
  logging, constants, utils / header, ttmath

type
  CountableList*[T] = ref object
    elements: seq[T] # TODO

  Block* = ref object of RootObj
    header*: Header
    uncles*: CountableList[Header]
    blockNumber*: Int256
