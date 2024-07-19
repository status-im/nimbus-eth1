# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

##
##  Definitions, Error Constants, etc.
## ===================================
##

{.push raises: [].}

type
  UtilsErrorType* = enum
    ##\
    ## Default/reset value (use `utilsNoError` below rather than this valie)
    resetUtilsError = (0, "no error")
    ##\
    ## is returned if the `extraData` header field does not seem to contain
    ## a 65 byte secp256k1 signature.
    errMissingSignature = "extraData 65 byte signature suffix missing"
    ##\
    ## Unsupported value of the (R,S) signature prefix V.
    errSigPrefixError = "unsupported (R,S) signature prefix V value"
    ##\
    ## eth/keys subsytem error: signature
    errSkSigResult = "signature error"
    ##\
    ## eth/keys subsytem error: public key
    errSkPubKeyResult = "public key error"
    ##\
    ## database lookup failed
    errItemNotFound = "not found"
    ##\
    ## TRansaction encoding error
    errTxEncError = "tx enc error"

  UtilsError* = ##\
    ## Error message, tinned component + explanatory text (if any)
    (UtilsErrorType, string)

const utilsNoError* = ##\
  ## No-error constant
  (resetUtilsError, "")

proc `$`*(e: UtilsError): string =
  ## Join text fragments
  result = $e[0]
  if e[1] != "":
    result &= ": " & e[1]

# End
