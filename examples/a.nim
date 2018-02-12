import vm/code_stream, opcode_values

var c = newCodeStream("\x60\x00\x60\x00\x60\x00\x60\x00\x67\x06\xf0\x5b\x59\xd3\xb2\x00\x00\x33\x60\xc8\x5a\x03\xf1")

let opcodes = c.decompile()
for op in opcodes:
  echo op[0], " ", op[1], " ", op[2]