import
  logging, constants, utils/header

type
  CountableList*[T] = ref object
    elements: seq[T] # TODO

  Block* = ref object of RootObj
    header*: Header
    uncles*: CountableList[Header]
