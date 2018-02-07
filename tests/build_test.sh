#!/bin/bash

nim --passC:"-I." cpp tests/code_stream_test.nim
nim --passC:"-I." cpp tests/gas_meter_test.nim
nim --passC:"-I." cpp tests/memory_test.nim
nim --passC:"-I." cpp tests/stack_test.nim
