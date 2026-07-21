/* Nimbus
 * Copyright (c) 2026 Status Research & Development GmbH
 * Licensed under either of
 *  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
 *    http://www.apache.org/licenses/LICENSE-2.0)
 *  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
 *    http://opensource.org/licenses/MIT)
 * at your option. This file may not be copied, modified, or distributed except
 * according to those terms.
 *
 * EIP-152 BLAKE2b F compression with a variable rounds parameter, built on the
 * official BLAKE2 reference source code package (CC0 1.0 / OpenSSL License /
 * Apache 2.0, Copyright 2012 Samuel Neves). The headers in this directory are
 * copied unmodified from https://github.com/BLAKE2/BLAKE2 (sse/ directory;
 * the two blake2-impl.h copies upstream are identical, one serves both paths
 * here).
 */

#include <stdint.h>
#include <string.h>

#if defined(__SSE2__) || defined(__x86_64__) || defined(__amd64__)

#include "blake2-config.h"

#include <emmintrin.h>
#if defined(HAVE_SSSE3)
#include <tmmintrin.h>
#endif
#if defined(HAVE_SSE41)
#include <smmintrin.h>
#endif
#if defined(HAVE_AVX)
#include <immintrin.h>
#endif
#if defined(HAVE_XOP)
#include <x86intrin.h>
#endif

#include "blake2-impl.h"
#include "blake2b-round.h"

static const uint64_t blake2b_IV[8] =
{
  0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
  0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
  0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
  0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

void nimbus_blake2b_f( uint32_t rounds, uint64_t h[8],
                       const uint8_t block[128],
                       const uint64_t t[2], int last )
{
  __m128i row1l, row1h;
  __m128i row2l, row2h;
  __m128i row3l, row3h;
  __m128i row4l, row4h;
  __m128i b0, b1;
  __m128i t0, t1;
#if defined(HAVE_SSSE3) && !defined(HAVE_XOP)
  const __m128i r16 = _mm_setr_epi8( 2, 3, 4, 5, 6, 7, 0, 1, 10, 11, 12, 13, 14, 15, 8, 9 );
  const __m128i r24 = _mm_setr_epi8( 3, 4, 5, 6, 7, 0, 1, 2, 11, 12, 13, 14, 15, 8, 9, 10 );
#endif
#if defined(HAVE_SSE41)
  const __m128i m0 = LOADU( block + 00 );
  const __m128i m1 = LOADU( block + 16 );
  const __m128i m2 = LOADU( block + 32 );
  const __m128i m3 = LOADU( block + 48 );
  const __m128i m4 = LOADU( block + 64 );
  const __m128i m5 = LOADU( block + 80 );
  const __m128i m6 = LOADU( block + 96 );
  const __m128i m7 = LOADU( block + 112 );
#else
  const uint64_t  m0 = load64(block +  0 * sizeof(uint64_t));
  const uint64_t  m1 = load64(block +  1 * sizeof(uint64_t));
  const uint64_t  m2 = load64(block +  2 * sizeof(uint64_t));
  const uint64_t  m3 = load64(block +  3 * sizeof(uint64_t));
  const uint64_t  m4 = load64(block +  4 * sizeof(uint64_t));
  const uint64_t  m5 = load64(block +  5 * sizeof(uint64_t));
  const uint64_t  m6 = load64(block +  6 * sizeof(uint64_t));
  const uint64_t  m7 = load64(block +  7 * sizeof(uint64_t));
  const uint64_t  m8 = load64(block +  8 * sizeof(uint64_t));
  const uint64_t  m9 = load64(block +  9 * sizeof(uint64_t));
  const uint64_t m10 = load64(block + 10 * sizeof(uint64_t));
  const uint64_t m11 = load64(block + 11 * sizeof(uint64_t));
  const uint64_t m12 = load64(block + 12 * sizeof(uint64_t));
  const uint64_t m13 = load64(block + 13 * sizeof(uint64_t));
  const uint64_t m14 = load64(block + 14 * sizeof(uint64_t));
  const uint64_t m15 = load64(block + 15 * sizeof(uint64_t));
#endif
  const uint64_t f[2] = { last ? (uint64_t)-1 : 0, 0 };
  uint32_t i, r;

  (void)t0; (void)t1;

  row1l = LOADU( &h[0] );
  row1h = LOADU( &h[2] );
  row2l = LOADU( &h[4] );
  row2h = LOADU( &h[6] );
  row3l = LOADU( &blake2b_IV[0] );
  row3h = LOADU( &blake2b_IV[2] );
  row4l = _mm_xor_si128( LOADU( &blake2b_IV[4] ), LOADU( &t[0] ) );
  row4h = _mm_xor_si128( LOADU( &blake2b_IV[6] ), LOADU( &f[0] ) );

  for( i = 0, r = 0; i < rounds; ++i )
  {
    switch( r )
    {
      case 0: ROUND( 0 ); break;
      case 1: ROUND( 1 ); break;
      case 2: ROUND( 2 ); break;
      case 3: ROUND( 3 ); break;
      case 4: ROUND( 4 ); break;
      case 5: ROUND( 5 ); break;
      case 6: ROUND( 6 ); break;
      case 7: ROUND( 7 ); break;
      case 8: ROUND( 8 ); break;
      case 9: ROUND( 9 ); break;
    }
    if( ++r == 10 ) r = 0;
  }

  row1l = _mm_xor_si128( row3l, row1l );
  row1h = _mm_xor_si128( row3h, row1h );
  STOREU( &h[0], _mm_xor_si128( LOADU( &h[0] ), row1l ) );
  STOREU( &h[2], _mm_xor_si128( LOADU( &h[2] ), row1h ) );
  row2l = _mm_xor_si128( row4l, row2l );
  row2h = _mm_xor_si128( row4h, row2h );
  STOREU( &h[4], _mm_xor_si128( LOADU( &h[4] ), row2l ) );
  STOREU( &h[6], _mm_xor_si128( LOADU( &h[6] ), row2h ) );
}

#else

#include "blake2-impl.h"

static const uint64_t blake2b_IV[8] =
{
  0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
  0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
  0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
  0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
};

static const uint8_t blake2b_sigma[10][16] =
{
  {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 } ,
  { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 } ,
  { 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 } ,
  {  7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 } ,
  {  9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 } ,
  {  2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 } ,
  { 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 } ,
  { 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 } ,
  {  6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 } ,
  { 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0 }
};

#define G(r,i,a,b,c,d)                      \
  do {                                      \
    a = a + b + m[blake2b_sigma[r][2*i+0]]; \
    d = rotr64(d ^ a, 32);                  \
    c = c + d;                              \
    b = rotr64(b ^ c, 24);                  \
    a = a + b + m[blake2b_sigma[r][2*i+1]]; \
    d = rotr64(d ^ a, 16);                  \
    c = c + d;                              \
    b = rotr64(b ^ c, 63);                  \
  } while(0)

#define ROUND(r)                    \
  do {                              \
    G(r,0,v[ 0],v[ 4],v[ 8],v[12]); \
    G(r,1,v[ 1],v[ 5],v[ 9],v[13]); \
    G(r,2,v[ 2],v[ 6],v[10],v[14]); \
    G(r,3,v[ 3],v[ 7],v[11],v[15]); \
    G(r,4,v[ 0],v[ 5],v[10],v[15]); \
    G(r,5,v[ 1],v[ 6],v[11],v[12]); \
    G(r,6,v[ 2],v[ 7],v[ 8],v[13]); \
    G(r,7,v[ 3],v[ 4],v[ 9],v[14]); \
  } while(0)

void nimbus_blake2b_f( uint32_t rounds, uint64_t h[8],
                       const uint8_t block[128],
                       const uint64_t t[2], int last )
{
  uint64_t m[16];
  uint64_t v[16];
  uint32_t i, r;

  for( i = 0; i < 16; ++i ) {
    m[i] = load64( block + i * sizeof( m[i] ) );
  }

  for( i = 0; i < 8; ++i ) {
    v[i] = h[i];
  }

  v[ 8] = blake2b_IV[0];
  v[ 9] = blake2b_IV[1];
  v[10] = blake2b_IV[2];
  v[11] = blake2b_IV[3];
  v[12] = blake2b_IV[4] ^ t[0];
  v[13] = blake2b_IV[5] ^ t[1];
  v[14] = last ? ~blake2b_IV[6] : blake2b_IV[6];
  v[15] = blake2b_IV[7];

  for( i = 0, r = 0; i < rounds; ++i )
  {
    switch( r )
    {
      case 0: ROUND( 0 ); break;
      case 1: ROUND( 1 ); break;
      case 2: ROUND( 2 ); break;
      case 3: ROUND( 3 ); break;
      case 4: ROUND( 4 ); break;
      case 5: ROUND( 5 ); break;
      case 6: ROUND( 6 ); break;
      case 7: ROUND( 7 ); break;
      case 8: ROUND( 8 ); break;
      case 9: ROUND( 9 ); break;
    }
    if( ++r == 10 ) r = 0;
  }

  for( i = 0; i < 8; ++i ) {
    h[i] = h[i] ^ v[i] ^ v[i + 8];
  }
}

#endif
