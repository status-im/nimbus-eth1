# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

proc utp_connect(enr: Record): SKey
proc utp_write(k: SKey, b: string): bool
proc utp_read(k: SKey, n: int): string
proc utp_get_connections(): seq[SKey]
proc utp_close(k: SKey): bool
