"""The iAkauntan mark: one grid, three shapes, no join to get wrong.

The i's stem drops into a bowl and the bowl rises into the A; the A has
no crossbar and comes down to a foot. Drawn as the dot, the J of the
stem and bowl, and the chevron of the A — the chevron's base runs down
inside the bowl so the two overlap solidly rather than meeting along an
edge, which is where a hairline would otherwise open up at some sizes.

A 1000-unit grid, so every size is exact.
"""
import math

S     = 1000
GREEN = '#0BD00B'
HW    = 64

DOT   = (120, 215, 248, 332)
STEM_X, STEM_TOP = 184, 378
BOWL_CX, BOWL_CY, BOWL_R = 300, 648, 116
ARM_X  = BOWL_CX + BOWL_R
APEX   = (610, 250)
PEAK_Y = 228
FOOT   = (826, 812)
# The chevron's base is cut level with the top of the bowl rather than
# square to the arm. The bowl ends on a horizontal edge, so anything else
# leaves a wedge of white on one side or pushes a corner out past the
# curve on the other — both of which were drawn before this was.

def _u(a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = math.hypot(dx, dy)
    return dx / n, dy / n

def _off(p, d, s):
    return (p[0] - d[1] * HW * s, p[1] + d[0] * HW * s)

def _cross(p, d, y):
    t = (y - p[1]) / d[1]
    return (p[0] + d[0] * t, y)

def _mitre(p, di, do, s):
    n1 = (-di[1] * s, di[0] * s)
    n2 = (-do[1] * s, do[0] * s)
    mx, my = n1[0] + n2[0], n1[1] + n2[1]
    m = math.hypot(mx, my)
    mx, my = mx / m, my / m
    k = HW / (mx * n1[0] + my * n1[1])
    return (p[0] + mx * k, p[1] + my * k)

def _arc(r, steps=96):
    return [(BOWL_CX + r * math.cos(math.radians(180 + 180 * i / steps)),
             BOWL_CY - r * math.sin(math.radians(180 + 180 * i / steps)))
            for i in range(steps + 1)]

def stem_and_bowl():
    pts  = [(STEM_X - HW, STEM_TOP)]
    pts += _arc(BOWL_R + HW)
    pts += [(ARM_X + HW, BOWL_CY), (ARM_X - HW, BOWL_CY)]
    pts += list(reversed(_arc(BOWL_R - HW)))
    pts += [(STEM_X + HW, STEM_TOP)]
    return pts

def chevron():
    d_arm = _u((ARM_X, BOWL_CY), APEX)
    d_leg = _u(APEX, FOOT)
    ao = _cross(_off((ARM_X, BOWL_CY), d_arm, -1), d_arm, BOWL_CY)
    ai = _cross(_off((ARM_X, BOWL_CY), d_arm, +1), d_arm, BOWL_CY)
    lo = _off(FOOT, d_leg, -1)
    li = _off(FOOT, d_leg, +1)
    return [ao,
            _cross(ao, d_arm, PEAK_Y),
            _cross(lo, d_leg, PEAK_Y),
            lo, li,
            _mitre(APEX, d_arm, d_leg, +1),
            ai]
