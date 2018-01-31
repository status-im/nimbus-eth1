#!/bin/bash

nim c tests/code_stream_test.nim
nim c tests/gas_meter_test.nim
./tests/code_stream_test
./tests/gas_meter_test
