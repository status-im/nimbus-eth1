import ../src/vm/code_stream, ../src/opcode_values, strformat

var c = newCodeStreamFromUnescaped("0x6003600202600055")

let opcodes = c.decompile()
for op in opcodes:
  echo &"[{op[0]}]\t{op[1]}\t{op[2]}"

# [1]     PUSH1   0x03
# [3]     PUSH1   0x02
# [4]     MUL
# [6]     PUSH1   0x00
# [7]     SSTORE
# [-1]    STOP
