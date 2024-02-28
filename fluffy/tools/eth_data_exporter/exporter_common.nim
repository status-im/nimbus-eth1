# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strutils, os],
  chronicles,
  stew/io2,
  faststreams,
  json_serialization,
  json_serialization/std/tables,
  ../../eth_data/history_data_json_store

export history_data_json_store

proc writePortalContentToJson*(
    fh: OutputStreamHandle, content: JsonPortalContentTable
) =
  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.writeValue(content)
  except IOError as e:
    fatal "Error occured while writing to file", error = e.msg
    quit 1

proc createAndOpenFile*(dataDir: string, fileName: string): OutputStreamHandle =
  # Creates directory and file, if file already exists
  # program is aborted with info to user, to avoid losing data
  let fileName: string =
    if not fileName.endsWith(".json"):
      fileName & ".json"
    else:
      fileName

  let filePath = dataDir / fileName

  if isFile(filePath):
    fatal "File under provided path already exists and would be overwritten",
      path = filePath
    quit 1

  let res = createPath(dataDir)
  if res.isErr():
    fatal "Error occurred while creating directory", error = ioErrorMsg(res.error)
    quit 1

  try:
    return fileOutput(filePath)
  except IOError as e:
    fatal "Error occurred while opening the file", error = e.msg
    quit 1
