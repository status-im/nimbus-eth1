
proc utp_connect(enr: Record): SKey
proc utp_write(k: SKey, b: string): bool
proc utp_read(k: SKey, n: int): string
proc utp_get_connections(): seq[SKey]
proc utp_close(k: SKey): bool
