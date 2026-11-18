# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Simple ETA package using at most three splines.
## ::
##      y,ranges 0..1
##        ^
##        |
##      1 + - - - - - - - - - - - - - - - P - - - - - -
##        |          y1
##        |          |        y2
##        |    y0    |        |
##        |    |     |        |
##        |    |     |        |
##      0 +----+-----+--------+------+----+----> x (time)
##             x0    x1       x2     x9   xp
##
## At time x9, the package calculates a straight line through (x0,y0) and
## (x2,y2) (or (x1,y1) if there is no (x2,y2) yet) and the intersection P
## with the horizontal line y=1. then ETA is calculated as xp - x9.
##

{.push raises:[].}

import
  std/math,
  pkg/chronos

type
  EtaSpline* = object
    ## A set of at most three splines for interpolating a straight line
    ## supported by the first and the last spline. The first two splines
    ## must have minimum distance `spDistMin1`. If any, the last two
    ## splines have maximum distance `spDistMax2`.
    spline: seq[(Moment,float)] # (x,y) pairs, interpreted as splines
    spDistMin1: Duration        # min distance between first couple of splines
    spDistMax2: Duration        # maximum distance between last splines couple

const
  EtaSplineDistMin1Default = chronos.minutes(2)
    ## Minimum spline distance for linear ETA interpolation. This is the
    ## initial interval which should be held deliberately small so that an
    ## ETA cacutlaion is available early.

  EtaSplineDistMax2Default = chronos.minutes(15)
    ## Maximum spline distance for linear ETA interpolation for other than the
    ## first two splines.

  # --------------

  TwoHundredYears* = chronos.days(365 * 200 + 48)
    ## Large Duration constant considered sort of infinite.

# ------------------------------------------------------------------------------
# Public ETA calculator API
# ------------------------------------------------------------------------------

proc init*(data: var EtaSpline, spDistMin1, spDistMax2: Duration) =
  ## Clear ETA data collector. The argument `spDistMin1` sets the required
  ## minimum distance beteeen the first couple of splines, the argument
  ## `spDistMax2` set the required maximum distance beteeen the last couple
  ## of splines.
  ##
  ## Required: 0 < `spDistMin1` <= `spDistMax2` (assertion enforced)
  data.spline.setLen(0)
  doAssert ZeroDuration < spDistMin1
  doAssert spDistMin1 <= spDistMax2
  data.spDistMin1 = spDistMin1
  data.spDistMax2 = spDistMax2

proc init*(data: var EtaSpline) =
  data.init(EtaSplineDistMin1Default, EtaSplineDistMax2Default)

proc apply*(data: var EtaSpline, y: float) =
  ## Add value between `0.0 .. 1.0` to ETA data collector.
  let x = Moment.now()
  case data.spline.len:
  of 0:
    if y <= 1.0:
      data.spline.add (x,y)
  of 1:
     if data.spDistMin1 < x - data.spline[0][0]:
       # (x,y) has minimum distance from the first spline. so add it
       data.spline.add (x,y)
  of 2:
    data.spline.add (x,y)
  of 3:
    if data.spDistMax2 < x - data.spline[1][0]:
      # (x,y) has at least maximum distance from the second spline. so replace
      # the three spline set by a spline tuple.
      data.spline = @[data.spline[1], (x,y)]
    else:
      # Replace last spline
      data.spline[2] = (x,y)
  else:
    raiseAssert "No more than 3 splines"

func eta*(data: EtaSpline): Opt[Duration] =
  ## Read out current ETA from data collector
  if data.spline.len < 2:
    return err()

  let y1 = data.spline[^1][1]                       # expect factor 0.0..1.0
  if 1.0 <= y1:                                     # beyond target already
    return ok(nanoseconds 0)

  let
    deltaX = (data.spline[^1][0] - data.spline[0][0]).nanoseconds
    y0 = data.spline[0][1]                          # factor 0.0..1.0

  # This must have been made certain by the `apply()` function
  doAssert data.spDistMin1.nanoseconds <= deltaX

  if y0.almostEqual(y1) or y1 < y0:                 # infinite horizon
    return err()

  let
    # Straight line: `y = m x + c` with `m = (y1-y0)/(x1-x0)`, `c = y1 - m x1`
    m = (y1 - y0) / deltaX.float                    # unit: 1/ns, non negative

    # Value 1 is reached at x9: `1 = m x9 + c` => `1 = m (x9 - x1) + y1`
    # At time x1, ETA is `x9 - x1 = (1 - y1) / m`
    H = (1.0 - y1) / m                              # unit: ns, non negative

  if TwoHundredYears.nanoseconds.float <= H:        # infinite horizon
    return err()

  # Convert to nanoseconde from float
  ok(nanoseconds H.int64)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
