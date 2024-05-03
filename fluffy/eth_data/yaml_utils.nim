# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/streams, yaml, results

export yaml

type YamlPortalContent* = object
  content_key*: string
  content_value*: string

proc loadFromYaml*(T: type, file: string): Result[T, string] =
  let s =
    try:
      openFileStream(file)
    except IOError as e:
      return err(e.msg)
  defer:
    try:
      close(s)
    except Exception as e:
      raiseAssert(e.msg)
  var res: T
  try:
    {.gcsafe.}:
      yaml.load(s, res)
  except YamlConstructionError as e:
    return err(e.msg)
  except YamlParserError as e:
    return err(e.msg)
  except OSError as e:
    return err(e.msg)
  except IOError as e:
    return err(e.msg)
  ok(res)

proc dumpToYaml*[T](value: T, file: string): Result[void, string] =
  let s = newFileStream(file, fmWrite)
  defer:
    try:
      close(s)
    except Exception as e:
      raiseAssert(e.msg)
  try:
    dump(value, s)
  except YamlPresenterJsonError as e:
    return err(e.msg)
  except YamlSerializationError as e:
    return err(e.msg)
  except YamlPresenterOutputError as e:
    return err(e.msg)
  ok()
