# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/os, stew/io2, chronicles

# Utils/consts/types only used to maintain backwards compatibility
# Functions or this file in its entirety should be removed when no longer needed
# They are put in this file to have a single place to maintain them making it
# more easy to search and remove them compared to when scattered across the codebase

const
  legacyEnrFileName* = "fluffy_node.enr"
  legacyLockFileName* = "fluffy.lock"
  legacyContentDbFileName* = "fluffy"

proc moveFileIfExists*(src, dst: string) =
  if fileAccessible(src, {AccessFlags.Find}):
    try:
      moveFile(src, dst)
    except CatchableError as e:
      fatal "Failed to move legacy file", src = src, dst = dst, error = e.msg
      quit QuitFailure
    except Exception as exc:
      raiseAssert exc.msg

proc legacyDataDir*(): string =
  let relativeDataDir =
    when defined(windows):
      "AppData" / "Roaming" / "Fluffy"
    elif defined(macosx):
      "Library" / "Application Support" / "Fluffy"
    else:
      ".cache" / "fluffy"

  getHomeDir() / relativeDataDir
