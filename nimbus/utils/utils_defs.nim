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

type
  UtilsErrorType* = enum
    resetUtilsError = ##\
      ## Default/reset value (use `utilsNoError` below rather than this valie)
      (0, "no error")

    errMissingSignature = ##\
      ## is returned if the `extraData` header field does not seem to contain
      ## a 65 byte secp256k1 signature.
      "extraData 65 byte signature suffix missing"

    errSigPrefixError = ##\
      ## Unsupported value of the (R,S) signature prefix V.
      "unsupported (R,S) signature prefix V value"

    errSkSigResult = ##\
      ## eth/keys subsytem error: signature
      "signature error"

    errSkPubKeyResult = ##\
      ## eth/keys subsytem error: public key
      "public key error"

    errItemNotFound = ##\
      ## database lookup failed
      "not found"

  UtilsError* = ##\
    ## Error message, tinned component + explanatory text (if any)
    (UtilsErrorType,string)


const
  utilsNoError* = ##\
    ## No-error constant
    (resetUtilsError, "")


proc `$`*(e: UtilsError): string {.inline.} =
  ## Join text fragments
  result = $e[0]
  if e[1] != "":
    result &= ": " & e[1]

# End
