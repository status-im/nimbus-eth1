import
  std/strutils

from os import DirSep, AltSep

const
  vendorPath  = currentSourcePath.rsplit({DirSep, AltSep}, 3)[0] & "/vendor"
  srcPath = vendorPath & "/libtommath"

{.passc: "-IMP_32BIT"}
{.compile: srcPath & "/mp_radix_size.c"}
{.compile: srcPath & "/mp_to_radix.c"}
{.compile: srcPath & "/mp_init_u64.c"}
{.compile: srcPath & "/mp_init_i32.c"}
{.compile: srcPath & "/mp_init_multi.c"}
{.compile: srcPath & "/mp_init.c"}
{.compile: srcPath & "/mp_init_size.c"}
{.compile: srcPath & "/mp_init_copy.c"}
{.compile: srcPath & "/mp_invmod.c"}
{.compile: srcPath & "/mp_abs.c"}
{.compile: srcPath & "/mp_set_u64.c"}
{.compile: srcPath & "/mp_set_u32.c"}
{.compile: srcPath & "/mp_set_i32.c"}
{.compile: srcPath & "/mp_get_i32.c"}
{.compile: srcPath & "/mp_get_i64.c"}
{.compile: srcPath & "/mp_exptmod.c"}
{.compile: srcPath & "/mp_clear_multi.c"}
{.compile: srcPath & "/mp_clear.c"}
{.compile: srcPath & "/mp_montgomery_reduce.c"}
{.compile: srcPath & "/mp_clamp.c"}
{.compile: srcPath & "/mp_grow.c"}
{.compile: srcPath & "/mp_mul.c"}
{.compile: srcPath & "/mp_mul_2.c"}
{.compile: srcPath & "/mp_mul_2d.c"}
{.compile: srcPath & "/mp_mod_2d.c"}
{.compile: srcPath & "/mp_log_n.c"}
{.compile: srcPath & "/mp_div_2.c"}
{.compile: srcPath & "/mp_div_d.c"}
{.compile: srcPath & "/mp_add.c"}
{.compile: srcPath & "/mp_sub.c"}
{.compile: srcPath & "/mp_exch.c"}
{.compile: srcPath & "/mp_rshd.c"}
{.compile: srcPath & "/mp_lshd.c"}
{.compile: srcPath & "/mp_zero.c"}
{.compile: srcPath & "/mp_dr_reduce.c"}
{.compile: srcPath & "/mp_cmp_mag.c"}
{.compile: srcPath & "/mp_cutoffs.c"}
{.compile: srcPath & "/mp_reduce.c"}
{.compile: srcPath & "/mp_count_bits.c"}
{.compile: srcPath & "/mp_montgomery_setup.c"}
{.compile: srcPath & "/mp_dr_setup.c"}
{.compile: srcPath & "/mp_reduce_2k_setup.c"}
{.compile: srcPath & "/mp_reduce_2k_setup_l.c"}
{.compile: srcPath & "/mp_reduce_2k.c"}
{.compile: srcPath & "/mp_reduce_2k_l.c"}
{.compile: srcPath & "/mp_reduce_is_2k_l.c"}
{.compile: srcPath & "/mp_reduce_is_2k.c"}
{.compile: srcPath & "/mp_reduce_setup.c"}
{.compile: srcPath & "/mp_dr_is_modulus.c"}
{.compile: srcPath & "/mp_mulmod.c"}
{.compile: srcPath & "/mp_set.c"}
{.compile: srcPath & "/mp_mod.c"}
{.compile: srcPath & "/mp_copy.c"}
{.compile: srcPath & "/mp_div.c"}
{.compile: srcPath & "/mp_div_2d.c"}
{.compile: srcPath & "/mp_mul_d.c"}
{.compile: srcPath & "/mp_2expt.c"}
{.compile: srcPath & "/mp_cmp.c"}
{.compile: srcPath & "/mp_cmp_d.c"}
{.compile: srcPath & "/mp_log.c"}
{.compile: srcPath & "/mp_sub_d.c"}
{.compile: srcPath & "/mp_add_d.c"}
{.compile: srcPath & "/mp_cnt_lsb.c"}
{.compile: srcPath & "/mp_expt_n.c"}
{.compile: srcPath & "/mp_get_mag_u32.c"}
{.compile: srcPath & "/mp_get_mag_u64.c"}
{.compile: srcPath & "/mp_from_ubin.c"}
{.compile: srcPath & "/mp_ubin_size.c"}
{.compile: srcPath & "/mp_to_ubin.c"}
{.compile: srcPath & "/mp_montgomery_calc_normalization.c"}
{.compile: srcPath & "/s_mp_exptmod.c"}
{.compile: srcPath & "/s_mp_exptmod_fast.c"}
{.compile: srcPath & "/s_mp_zero_digs.c"}
{.compile: srcPath & "/s_mp_montgomery_reduce_comba.c"}
{.compile: srcPath & "/s_mp_add.c"}
{.compile: srcPath & "/s_mp_sub.c"}
{.compile: srcPath & "/s_mp_mul.c"}
{.compile: srcPath & "/s_mp_mul_comba.c"}
{.compile: srcPath & "/s_mp_mul_toom.c"}
{.compile: srcPath & "/s_mp_mul_karatsuba.c"}
{.compile: srcPath & "/s_mp_mul_balance.c"}
{.compile: srcPath & "/s_mp_copy_digs.c"}
{.compile: srcPath & "/s_mp_div_3.c"}
{.compile: srcPath & "/s_mp_sqr.c"}
{.compile: srcPath & "/s_mp_sqr_comba.c"}
{.compile: srcPath & "/s_mp_sqr_toom.c"}
{.compile: srcPath & "/s_mp_sqr_karatsuba.c"}
{.compile: srcPath & "/s_mp_zero_buf.c"}
{.compile: srcPath & "/s_mp_radix_map.c"}
{.compile: srcPath & "/s_mp_invmod.c"}
{.compile: srcPath & "/s_mp_invmod_odd.c"}
{.compile: srcPath & "/s_mp_mul_high.c"}
{.compile: srcPath & "/s_mp_mul_high_comba.c"}
{.compile: srcPath & "/s_mp_div_recursive.c"}
{.compile: srcPath & "/s_mp_div_school.c"}
{.compile: srcPath & "/s_mp_fp_log_d.c"}
{.compile: srcPath & "/s_mp_fp_log.c"}

{.passc: "-I" & srcPath .}

type
  mp_int {.importc: "mp_int",
    header: "tommath.h", byref.} = object

  mp_digit = uint32

  mp_err {.importc: "mp_err",
    header: "tommath.h".} = cint

  mp_ord = cint

{.pragma: mp_abi, importc, cdecl, header: "tommath.h".}

const
  MP_OKAY = 0.mp_err

  MP_LT = -1
  MP_EQ = 0
  MP_GT = 1

template getPtr(z: untyped): untyped =
  when (NimMajor, NimMinor) > (1,6):
    z.addr
  else:
    z.unsafeAddr

# init a bignum
# proc mp_init(a: mp_int): mp_err {.mp_abi.}
# proc mp_init_size(a: mp_int, size: cint): mp_err {.mp_abi.}

# init multiple bignum, 2nd, 3rd, and soon use addr, terminated with nil
proc mp_init_multi(mp: mp_int): mp_err {.mp_abi, varargs.}

# free a bignum
proc mp_clear(a: mp_int) {.mp_abi.}

# clear multiple mp_ints, terminated with nil
proc mp_clear_multi(mp: mp_int) {.mp_abi, varargs.}

# compare against a single digit
proc mp_cmp_d(a: mp_int, b: mp_digit): mp_ord {.mp_abi.}

# conversion from/to big endian bytes
proc mp_ubin_size(a: mp_int): csize_t {.mp_abi.}
proc mp_from_ubin(a: mp_int, buf: ptr byte, size: csize_t): mp_err {.mp_abi.}
proc mp_to_ubin(a: mp_int, buf: ptr byte, maxlen: csize_t, written: var csize_t): mp_err {.mp_abi.}

# Y = G**X (mod P)
proc mp_exptmod(G, X, P, Y: mp_int): mp_err {.mp_abi.}

proc mp_get_i32(a: mp_int): int32 {.mp_abi.}
proc mp_get_u32(a: mp_int): uint32 =
  cast[uint32](mp_get_i32(a))

# proc mp_init_u64(a: mp_int, b: uint64): mp_err {.mp_abi.}
# proc mp_set_u64(a: mp_int, b: uint64) {.mp_abi.}

proc mp_to_radix(a: mp_int, str: ptr char, maxlen: csize_t, written: var csize_t, radix: cint): mp_err {.mp_abi.}
proc mp_radix_size(a: mp_int, radix: cint, size: var csize_t): mp_err {.mp_abi.}

proc toString*(a: mp_int): string =
  var size: csize_t
  if mp_radix_size(a, 10.cint, size) != MP_OKAY:
    return
  if size.int == 0:
    return
  result = newString(size.int)
  if mp_to_radix(a, result[0].getPtr, size, size, 10.cint) != MP_OKAY:
    return
  result.setLen(size-1)

proc modExp*(b, e, m: openArray[byte]): seq[byte] =
  var
    base, exp, modulo, res: mp_int

  if mp_init_multi(base, exp.addr, modulo.addr, nil) != MP_OKAY:
    return

  if m.len > 0:
    discard mp_from_ubin(modulo, m[0].getPtr, m.len.csize_t)
    if mp_cmp_d(modulo, 1.mp_digit) <= MP_EQ:
      # EVM special case 1
      # If m == 0: EVM returns 0.
      # If m == 1: we can shortcut that to 0 as well
      mp_clear(modulo)
      return @[0.byte]

  if e.len > 0:
    discard mp_from_ubin(exp, e[0].getPtr, e.len.csize_t)
    if mp_cmp_d(exp, 0.mp_digit) == MP_EQ:
      # EVM special case 2
      # If 0^0: EVM returns 1
      # For all x != 0, x^0 == 1 as well
      mp_clear_multi(exp, modulo.addr, nil)
      return @[1.byte]

  if b.len > 0:
    discard mp_from_ubin(base, b[0].getPtr, b.len.csize_t)

  if mp_exptmod(base, exp, modulo, res) == MP_OKAY:
    let size = mp_ubin_size(res)
    if size.int > 0:
      var written: csize_t
      result = newSeq[byte](size.int)
      discard mp_to_ubin(res, result[0].getPtr, size, written)
      result.setLen(written)

  mp_clear_multi(base, exp.addr, modulo.addr, res.addr, nil)
