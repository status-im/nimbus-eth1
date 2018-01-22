import
  constants, bigints, errors

type
  BaseTransaction* = ref object
    nonce*: Int256
    gasPrice*: Int256
    gas*: Int256
    to*: cstring
    value*: Int256
    data*: cstring
    v*: Int256
    r*: Int256
    s*: Int256

proc intrinsicGas*(t: BaseTransaction): Int256 =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation)
  raise newException(ValueError, "not implemented intrinsicGas")






proc validate*(t: BaseTransaction) =
  # Hook called during instantiation to ensure that all transaction
  # parameters pass validation rules
  if t.intrinsicGas() > t.gas:
    raise newException(ValidationError, "Insufficient gas")
  #  self.check_signature_validity()

proc sender*(t: BaseTransaction): cstring =
  # TODO
  cstring""