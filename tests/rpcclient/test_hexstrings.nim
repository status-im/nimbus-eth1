# Separated from main tests for brevity

import unittest, ../../nimbus/rpc/hexstrings, json

proc doHexStrTests* =
  suite "Hex quantity":
    test "Empty string":
      expect ValueError:
        let
          source = ""
          x = hexQuantityStr source
        check %x == %source
    test "Even length":
      let
        source = "0x123"
        x = hexQuantityStr source
      check %x == %source
    test "Odd length":
      let
        source = "0x123"
        x = hexQuantityStr"0x123"
      check %x == %source
    test "Missing header":
      expect ValueError:
        let
          source = "1234"
          x = hexQuantityStr source
        check %x != %source
      expect ValueError:
        let
          source = "01234"
          x = hexQuantityStr source
        check %x != %source
      expect ValueError:
        let
          source = "x1234"
          x = hexQuantityStr source
        check %x != %source
      
  suite "Hex data":
    test "Even length":
      let
        source = "0x1234"
        x = hexDataStr source
      check %x == %source
    test "Odd length":
      expect ValueError:
        let
          source = "0x123"
          x = hexDataStr source
        check %x != %source
    test "Missing header":
      expect ValueError:
        let
          source = "1234"
          x = hexDataStr source
        check %x != %source
      expect ValueError:
        let
          source = "01234"
          x = hexDataStr source
        check %x != %source
      expect ValueError:
        let
          source = "x1234"
          x = hexDataStr source
        check %x != %source
