# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Yellow Paper Appendix H -
## https://ethereum.github.io/yellowpaper/paper.pdf
##
## Special notes from Yellow Paper:
##   - Signed values are treated as two’s complement signed 256-bit
##     integers.
##   - When −2^255 is negated, there is an overflow
##   - For addmod and mulmod, intermediate computations are not subject to
##     the 2^256 modulo.
##
## Nimbus authors note:
##   - This means that we can't naively do (UInt256 + UInt256) mod uint256,
##     because the intermediate sum (or multiplication) might roll over if
##     intermediate result is greater or equal 2^256

type
  Op* = enum
    # 0s: Stop and Arithmetic Operations
    Stop =           0x00, ## Halts execution.
    Add =            0x01, ## Addition operation.
    Mul =            0x02, ## Multiplication operation.
    Sub =            0x03, ## Subtraction operation.
    Div =            0x04, ## Integer division operation.
    Sdiv =           0x05, ## Signed integer division operation (truncated).
    Mod =            0x06, ## Modulo remainder operation.
    Smod =           0x07, ## Signed modulo remainder operation.
    Addmod =         0x08, ## Modulo addition operation.
    Mulmod =         0x09, ## Modulo multiplication operation.
    Exp =            0x0A, ## Exponentiation operation
    SignExtend =     0x0B, ## Extend length of two’s complement signed
                           ## integer.

    Nop0x0C, Nop0x0D, Nop0x0E, Nop0x0F, ## ..

    # 10s: Comparison & Bitwise Logic Operations
    Lt =             0x10, ## Less-than comparison.
    Gt =             0x11, ## Greater-than comparison.
    Slt =            0x12, ## Signed less-than comparison.
    Sgt =            0x13, ## Signed greater-than comparison.
    Eq =             0x14, ## Equality comparison.
    IsZero =         0x15, ## Simple not operator. (Note: real Yellow Paper
                           ## description)
    And =            0x16, ## Bitwise AND operation.
    Or =             0x17, ## Bitwise OR operation.
    Xor =            0x18, ## Bitwise XOR operation.
    Not =            0x19, ## Bitwise NOT operation.
    Byte =           0x1A, ## Retrieve single byte from word.
    Shl =            0x1B, ## Shift left
    Shr =            0x1C, ## Logical shift right
    Sar =            0x1D, ## Arithmetic shift right

    Nop0x1E, Nop0x1F, ## ..

    # 20s: SHA3
    Sha3 =           0x20, ## Compute Keccak-256 hash.

    Nop0x21, Nop0x22, Nop0x23, Nop0x24, Nop0x25, Nop0x26,
    Nop0x27, Nop0x28, Nop0x29, Nop0x2A, Nop0x2B, Nop0x2C,
    Nop0x2D, Nop0x2E, Nop0x2F, ## ..

    # 30s: Environmental Information
    Address =        0x30, ## Get address of currently executing account.
    Balance =        0x31, ## Get balance of the given account.
    Origin =         0x32, ## Get execution origination address.
    Caller =         0x33, ## Get caller address.
    CallValue =      0x34, ## Get deposited value by the
                           ## instruction/transaction responsible for this
                           ## execution.
    CallDataLoad =   0x35, ## Get input data of current environment.
    CallDataSize =   0x36, ## Get size of input data in current environment.
    CallDataCopy =   0x37, ## Copy input data in current environment to
                           ## memory.
    CodeSize =       0x38, ## Get size of code running in current environment.
    CodeCopy =       0x39, ## Copy code running in current environment to
                           ## memory.
    GasPrice =       0x3a, ## Get price of gas in current environment.
    ExtCodeSize =    0x3b, ## Get size of an account's code
    ExtCodeCopy =    0x3c, ## Copy an account's code to memory.
    ReturnDataSize = 0x3d, ## Get size of output data from the previous call
                           ## from the current environment.
    ReturnDataCopy = 0x3e, ## Copy output data from the previous call to
                           ## memory.
    ExtCodeHash =    0x3f, ## Returns the keccak256 hash of a contract’s code

    # 40s: Block Information
    Blockhash =      0x40, ## Get the hash of one of the 256 most recent
                           ## complete blocks.
    Coinbase =       0x41, ## Get the block's beneficiary address.
    Timestamp =      0x42, ## Get the block's timestamp.
    Number =         0x43, ## Get the block's number.
    Difficulty =     0x44, ## Get the block's difficulty.
    GasLimit =       0x45, ## Get the block's gas limit.

    ChainIdOp =      0x46, ## Get current chain’s EIP-155 unique identifier.
    SelfBalance =    0x47, ## Get current contract's balance.
    BaseFee =        0x48, ## Get block’s base fee. EIP-3198
    BlobHash =       0x49, ## Get transaction's versionedHash. EIP-4844
    BlobBaseFee =    0x4A, ## Returns the current data-blob base-fee

    Nop0x4B, Nop0x4C, Nop0x4D,
    Nop0x4E, Nop0x4F, ## ..

    # 50s: Stack, Memory, Storage and Flow Operations
    Pop =            0x50, ## Remove item from stack.
    Mload =          0x51, ## Load word from memory.
    Mstore =         0x52, ## Save word to memory.
    Mstore8 =        0x53, ## Save byte to memory.
    Sload =          0x54, ## Load word from storage.
    Sstore =         0x55, ## Save word to storage.
    Jump =           0x56, ## Alter the program counter.
    JumpI =          0x57, ## Conditionally alter the program counter.
    Pc =             0x58, ## Get the value of the program counter prior to
                           ## the increment corresponding to this instruction.
    Msize =          0x59, ## Get the size of active memory in bytes.
    Gas =            0x5a, ## Get the amount of available gas, including the
                           ## corresponding reduction for the cost of this
                           ## instruction.
    JumpDest =       0x5b, ## Mark a valid destination for jumps. This
                           ## operation has no effect on machine state during
                           ## execution.

    Tload =          0x5c, ## Load word from transient storage.
    Tstore =         0x5d, ## Save word to transient storage.

    Mcopy =          0x5e, ## Memory copy

    # 5f, 60s & 70s: Push Operations.
    Push0 =          0x5f, ## Place 0 on stack. EIP-3855
    Push1 =          0x60, ## Place 1-byte item on stack.
    Push2 =          0x61, ## Place 2-byte item on stack.

    Push3,  Push4,  Push5,  Push6,  Push7,  Push8,
    Push9,  Push10, Push11, Push12, Push13, Push14,
    Push15, Push16, Push17, Push18, Push19, Push20,
    Push21, Push22, Push23, Push24, Push25, Push26,
    Push27, Push28, Push29, Push30, Push31, ## ..

    Push32 =          0x7f, ## Place 32-byte (full word) item on stack.

    # 80s: Duplication Operations
    Dup1 =           0x80, ## Duplicate 1st stack item.
    Dup2 =           0x81, ## Duplicate 2nd stack item.

    Dup3,  Dup4,  Dup5,  Dup6,  Dup7,  Dup8,
    Dup9,  Dup10, Dup11, Dup12, Dup13, Dup14,
    Dup15, ## ..

    Dup16 =          0x8f, ## Duplicate 16th stack item.

    # 90s: Exchange Operations
    Swap1 =          0x90, ## Exchange 1st and 2nd stack items.
    Swap2 =          0x91, ## Exchange 1st and 3rd stack items.

    Swap3,  Swap4,  Swap5,  Swap6,  Swap7,  Swap8,
    Swap9,  Swap10, Swap11, Swap12, Swap13, Swap14,
    Swap15, ## ..

    Swap16 =         0x9f, ## Exchange 1st and 17th stack items.

    # a0s: Logging Operations
    Log0 =           0xa0, ## Append log record with no topics.
    Log1 =           0xa1, ## Append log record with one topics.

    Log2, Log3, ## ..

    Log4 =           0xa4, ## Append log record with four topics.

    Nop0xA5, Nop0xA6, Nop0xA7, Nop0xA8, Nop0xA9, Nop0xAA,
    Nop0xAB, Nop0xAC, Nop0xAD, Nop0xAE, Nop0xAF, Nop0xB0,
    Nop0xB1, Nop0xB2, Nop0xB3, Nop0xB4, Nop0xB5, Nop0xB6,
    Nop0xB7, Nop0xB8, Nop0xB9, Nop0xBA, Nop0xBB, Nop0xBC,
    Nop0xBD, Nop0xBE, Nop0xBF, Nop0xC0, Nop0xC1, Nop0xC2,
    Nop0xC3, Nop0xC4, Nop0xC5, Nop0xC6, Nop0xC7, Nop0xC8,
    Nop0xC9, Nop0xCA, Nop0xCB, Nop0xCC, Nop0xCD, Nop0xCE,
    Nop0xCF, Nop0xD0, Nop0xD1, Nop0xD2, Nop0xD3, Nop0xD4,
    Nop0xD5, Nop0xD6, Nop0xD7, Nop0xD8, Nop0xD9, Nop0xDA,
    Nop0xDB, Nop0xDC, Nop0xDD, Nop0xDE, Nop0xDF,

    Rjump =          0xe0, ## Relative jump (EIP4200)
    RJumpI =         0xe1, ## Conditional relative jump (EIP4200)
    RJumpV =         0xe2, ## Relative jump via jump table (EIP4200)

    Nop0xE3, Nop0xE4, Nop0xE5, Nop0xE6,
    Nop0xE7, Nop0xE8, Nop0xE9, Nop0xEA, Nop0xEB, Nop0xEC,
    Nop0xED, Nop0xEE, Nop0xEF, ## ..

    # f0s: System operations
    Create =         0xf0, ## Create a new account with associated code.
    Call =           0xf1, ## Message-call into an account.
    CallCode =       0xf2, ## Message-call into this account with an
                           ## alternative account's code.
    Return =         0xf3, ## Halt execution returning output data.
    DelegateCall =   0xf4, ## Message-call into this account with an
                           ## alternative account's code, but persisting the
                           ## current values for sender and value.
    Create2 =        0xf5, ## Behaves identically to CREATE, except using
                           ## keccak256

    Nop0xF6, Nop0xF7, Nop0xF8, Nop0xF9,  ## ..

    StaticCall =     0xfa, ## Static message-call into an account.

    Nop0xFB, Nop0xFC, ## ..

    Revert =         0xfd, ## Halt execution reverting state changes but
                           ## returning data and remaining gas.
    Invalid =        0xfe, ## Designated invalid instruction.
    SelfDestruct =   0xff  ## Halt execution and register account for later
                           ## deletion.

const
  # EIP-4399 new opcode
  PrevRandao* = Difficulty

# ------------------------------------------------------------------------------
# Verify that Op is contiguous and sym names follow some standards
# ------------------------------------------------------------------------------

import strutils, sequtils
static:
  type Vfy = enum
    VfyStop = 0x00,
    VfySelfDestruct = 0xff

  const
    allowedChars = {'A'..'Z', 'a'..'z', '0'..'9'}

  # Enum holes look like: "Op 123" (space triggers error)
  proc badSymNames(a: openArray[string]): seq[string] =
    toSeq(a).filterIt(it.len < 2 or
                      not it[0].isUpperAscii or
                      it.count(allowedChars) < it.len)

  const
    vfySymNames = toSeq(0 .. 255).mapIt($it.Vfy).badSymNames
    opSymNames = toSeq(0 .. 255).mapIt($it.Op).badSymNames

  # control test, values 1..254 must be rejected
  when vfySymNames.len != 254:
    static:
      echo "*** Got only ", vfySymNames.len,
           " rejected Vfy enum symbols (expected 254)"
    {.fatal: "Compiler logic might have changed -- please fix"}

  # verify Op enum/table
  when 0 < opSymNames.len:
    static:
      echo "*** Unexpected enum symbols: \"", opSymNames.join("\", "), '"'
    {.fatal: "Probably holes in Op enum -- please fix"}

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
