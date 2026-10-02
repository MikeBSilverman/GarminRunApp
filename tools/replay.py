#!/usr/bin/env python3
"""Replay a recorded run through CourseRun's logic and report what the field
would have shown.

    python tools/replay.py activity.fit                     # current code
    python tools/replay.py activity.fit --legacy            # v0.2.0 behaviour
    python tools/replay.py activity.fit --target-units mps  # firmware hands m/s
    python tools/replay.py activity.fit --csv out.csv --changes

Input comes from the activity FIT file (download "Export Original" from
Garmin Connect): per-second timer time, GPS distance, heart rate, the field's
own recorded course distance (developer field `course_dist`, if CourseRun was
on the watch) and the workout steps with the laps that mark step changes.
From v0.3.0 the field also records `band_status` each second; when present,
the report shows how often the replay agrees with what the watch showed.

distanceToDestination is not in the FIT file, so CourseTracker itself is not
replayed: the course distance the field recorded is used as-is (or GPS
distance with --gps, or for files recorded without CourseRun). Everything
downstream is: PaceBuffer (smoothed speed), WorkoutTarget (target parsing,
hysteresis, settle period) and the band status and alerts.

The ports below mirror source/*.mc; keep them in step when that logic changes.

Needs: pip install fitparse
"""
import argparse
import csv
import sys

try:
    import fitparse
except ImportError:
    sys.exit("needs fitparse: pip install fitparse")

M_PER_MI = 1609.344
M_PER_KM = 1000.0

NONE, ON, FAST, SLOW = 0, 1, 2, 3
STATUS_NAME = {NONE: "--", ON: "ON PACE", FAST: "SLOW DOWN", SLOW: "SPEED UP"}

# FIT workout_step intensity enum (also Activity.WORKOUT_INTENSITY_*).
INTENSITY = {0: "active", 1: "rest", 2: "warmup", 3: "cooldown", 4: "recovery", 5: "interval", 6: "other"}


# ---- ports of the Monkey C models ------------------------------------------

class PaceBuffer:
    """source/PaceBuffer.mc"""

    def __init__(self, cap=900, interval_ms=2000):
        self.cap, self.interval = cap, interval_ms
        self.t, self.d = [], []

    def add(self, t, d):
        if self.t:
            if t < self.t[-1]:
                self.t, self.d = [], []
            elif t - self.t[-1] < self.interval:
                return
        self.t.append(t)
        self.d.append(d)
        if len(self.t) > self.cap:
            self.t.pop(0)
            self.d.pop(0)

    def _interp(self, xs, ys, x):
        if not xs or x < xs[0]:
            return None
        lo, hi = 0, len(xs) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if xs[mid] <= x:
                lo = mid
            else:
                hi = mid - 1
        if lo == len(xs) - 1 or xs[lo + 1] - xs[lo] <= 0:
            return float(ys[lo])
        return ys[lo] + (ys[lo + 1] - ys[lo]) * (x - xs[lo]) / (xs[lo + 1] - xs[lo])

    def time_at_distance(self, dist):
        return self._interp(self.d, self.t, dist)

    def distance_at_time(self, t):
        return self._interp(self.t, self.d, t)

    def rolling_sec_per_meter(self, now_t, now_d, window_m):
        start = now_d - window_m
        if window_m <= 0 or start < 0:
            return None
        ts = self.time_at_distance(start)
        if ts is None or now_t - ts <= 0:
            return None
        return (now_t - ts) / 1000.0 / window_m

    def smoothed_speed(self, now_t, now_d, window_ms):
        if not self.t:
            return None
        t0 = now_t - window_ms
        if t0 < self.t[0]:
            if now_t - self.t[0] < 5000:
                return None
            t0, d0 = self.t[0], self.d[0]
        else:
            d0 = self.distance_at_time(t0)
        if d0 is None or now_t - t0 <= 0:
            return None
        return max(0.0, (now_d - d0) * 1000.0 / (now_t - t0))


class WorkoutTarget:
    """source/WorkoutTarget.mc (speed targets; HR targets need max HR zones)"""
    OPEN_HIGH = 99.0
    HYST = 0.015

    def __init__(self, legacy=False):
        self.legacy = legacy
        self.kind = None   # "pace" / "hr" / None
        self.low = self.high = 0.0
        self.status = NONE

    def speed_value(self, v):
        # Firmware reports speed targets either as mm/s or m/s. Anything below
        # SPEED_MMPS_MIN can't be mm/s for a run (0.1 m/s), so it is m/s.
        if self.legacy:
            return v / 1000.0
        return v / 1000.0 if v >= 100 else float(v)

    def set_from(self, target_type, lo, hi, max_hr=None):
        self.kind = None
        if target_type == "speed":
            if lo <= 0 and hi <= 0:
                return
            a, b = self.speed_value(lo), self.speed_value(hi)
            if a > 0 and b > 0 and a > b:
                a, b = b, a
            self.low = a if a > 0 else 0.0
            self.high = b if b > 0 else self.OPEN_HIGH
            self.kind = "pace"
        elif target_type == "heart_rate":
            if lo > 100 or hi > 100:
                self.low, self.high = float(lo - 100 if lo > 100 else lo), float(hi - 100 if hi > 100 else hi)
            elif max_hr and lo > 0 and hi > 0:
                self.low, self.high = max_hr * lo / 100.0, max_hr * hi / 100.0
            else:
                return
            self.low, self.high = min(self.low, self.high), max(self.low, self.high)
            self.kind = "hr"

    def evaluate(self, speed, hr):
        v = speed if self.kind == "pace" else (hr if self.kind == "hr" else None)
        if v is None:
            self.status = NONE
            return NONE
        lo, hi, h = self.low, self.high, self.HYST
        nxt = ON
        if self.status == FAST:
            nxt = FAST if v > hi else (SLOW if v < lo * (1 - h) else ON)
        elif self.status == SLOW:
            nxt = SLOW if v < lo else (FAST if v > hi * (1 + h) else ON)
        else:
            if v > hi * (1 + h):
                nxt = FAST
            elif v < lo * (1 - h):
                nxt = SLOW
        self.status = nxt
        return nxt


class CourseTracker:
    """source/CourseTracker.mc"""
    GPS, COURSE, OFF = 0, 1, 2
    RELOCK_MIN_M, STALL_SECS, STALL_GPS_M, RESCALE_TOL, START_SNAP_M, CATCHUP_M = 500.0, 20, 50.0, 0.05, 100.0, 400.0
    LEAP_M = 400.0

    def __init__(self, official=0.0):
        self.course_dist, self.mode, self.mismatch = 0.0, self.GPS, False
        self.length, self.official = None, official
        self.last_gps, self.stall_ticks, self.stall_gps = None, 0, 0.0
        self.last_cand = None

    def _check(self):
        self.mismatch = False
        if self.official > 0 and self.length:
            r = self.length / self.official
            self.mismatch = r > 1 + self.RESCALE_TOL or r < 1 - self.RESCALE_TOL

    def _use_official(self):
        return self.official > 0 and self.length is not None and not self.mismatch

    def preview(self, dtd):
        if dtd is not None and dtd > 0 and (self.length is None or dtd > self.length):
            self.length = dtd
            self._check()

    def update(self, gps, dtd):
        first = self.last_gps is None
        delta = 0.0
        if self.last_gps is not None:
            delta = max(0.0, gps - self.last_gps)
        self.last_gps = gps
        if dtd is None or dtd < 0:
            self.last_cand = None
            self.course_dist += delta
            if self.mode == self.COURSE:
                self.mode = self.OFF
            return
        implied = dtd + self.course_dist
        if first and self.length is not None and 0 < self.length - dtd < self.START_SNAP_M:
            self.length = dtd
            self._check()
        if self.length is None:
            self.length = implied
            self._check()
        else:
            early = self.course_dist < self.RELOCK_MIN_M or self.course_dist < self.length * 0.1
            if early and implied > self.length * (1 + self.RESCALE_TOL):
                self.length = implied
                self._check()
        cand = self.length - dtd
        if self._use_official() and self.length > 0:
            cand = cand * self.official / self.length
        if not first and cand - self.course_dist > delta * 2.0 + self.LEAP_M:
            self.last_cand = None
            cand = self.course_dist
        step = cand - self.last_cand if self.last_cand is not None else 0.0
        self.last_cand = cand
        if cand > self.course_dist:
            self.course_dist, self.mode = cand, self.COURSE
            self.stall_ticks, self.stall_gps = 0, 0.0
            return
        if step > 1.0 and step >= delta * 0.5 and self.course_dist - cand < self.CATCHUP_M:
            self.course_dist += step * 0.5
            self.mode = self.COURSE
            self.stall_ticks, self.stall_gps = 0, 0.0
            return
        self.stall_ticks += 1
        self.stall_gps += delta
        if self.mode == self.OFF:
            self.course_dist += delta
        elif self.stall_ticks >= self.STALL_SECS and self.stall_gps >= self.STALL_GPS_M:
            self.mode = self.OFF
            self.course_dist += self.stall_gps


class CourseMatcher:
    """Stand-in for the watch's distanceToDestination: project each GPS fix
    onto the course line, searching forward from the last match so the shared
    start/finish of a loop and out-and-back overlaps resolve by progress.
    Garmin's own algorithm isn't published; compare against the recorded
    course_dist to see how close this is."""
    LOOK_BACK_M, LOOK_AHEAD_M, OFF_COURSE_M = 50.0, 400.0, 40.0

    def __init__(self, pts):
        # pts: [(lat_deg, lon_deg, cum_dist_m)]
        import math
        self.lat0 = pts[0][0]
        self.kx = 111320.0 * math.cos(math.radians(self.lat0))
        self.xy = [((lo * self.kx), (la * 110540.0)) for la, lo, _ in pts]
        self.s = [p[2] for p in pts]
        self.length = self.s[-1]
        self.i = None
        self.s_cur = 0.0
        self.off = False

    def dtd_before_start(self, lat, lon):
        """Before START: distance to the course start plus its length, as the
        watch reports when you're not yet on it."""
        x, y = lon * self.kx, lat * 110540.0
        return self.length + ((x - self.xy[0][0]) ** 2 + (y - self.xy[0][1]) ** 2) ** 0.5

    def dtd(self, lat, lon, moved=0.0):
        """Distance to destination for a fix; `moved` is the GPS distance
        since the last fix. Where the route doubles back (out-and-back legs,
        laps) several stretches are equally close, so among the candidates
        near the best, take the one closest to the expected progress."""
        x, y = lon * self.kx, lat * 110540.0
        if self.i is None:
            lo, hi, expect = 0, self._index_at(min(500.0, self.length / 4)), 0.0
        else:
            cur = self.s_cur
            # Back one point: the segment we're on can start well before
            # cur - LOOK_BACK_M when the route has long straight segments.
            lo = max(0, self._index_at(cur - self.LOOK_BACK_M) - 1)
            hi = self._index_at(cur + max(self.LOOK_AHEAD_M, moved * 3))
            expect = cur + moved
        cands = []
        for j in range(lo, min(hi + 1, len(self.xy) - 1)):
            (ax, ay), (bx, by) = self.xy[j], self.xy[j + 1]
            dx, dy = bx - ax, by - ay
            L2 = dx * dx + dy * dy
            u = 0.0 if L2 == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / L2))
            dd = ((x - ax - u * dx) ** 2 + (y - ay - u * dy) ** 2) ** 0.5
            cands.append((dd, j, self.s[j] + u * (self.s[j + 1] - self.s[j])))
        if not cands:
            return None
        best = min(c[0] for c in cands)
        self.off = best > self.OFF_COURSE_M
        if self.off and self.i is not None:
            return self.length - self.s_cur   # frozen while off course
        near = [c for c in cands if c[0] <= max(best + 10.0, 15.0)]
        dd, j, sv = min(near, key=lambda c: abs(c[2] - expect))
        self.i, self.s_cur = j, sv
        return self.length - sv

    def _index_at(self, dist):
        import bisect
        return max(0, min(len(self.s) - 1, bisect.bisect_left(self.s, dist)))


def load_course(path, laps=1):
    """Course points [(lat, lon, cum m)] from a course FIT or a GPX file,
    repeated `laps` times for a lapped race given as one lap."""
    import math
    pts = []
    if path.lower().endswith(".gpx"):
        import xml.etree.ElementTree as ET
        for el in ET.parse(path).getroot().iter():
            if el.tag.endswith("trkpt") or el.tag.endswith("rtept"):
                pts.append((float(el.get("lat")), float(el.get("lon")), None))
    else:
        for m in fitparse.FitFile(path).get_messages("record"):
            v = {x.name: x.value for x in m.fields}
            if v.get("position_lat") is None:
                continue
            k = 180.0 / 2 ** 31
            pts.append((v["position_lat"] * k, v["position_long"] * k, v.get("distance")))
    if not pts:
        sys.exit(f"no course points in {path}")
    if any(p[2] is None for p in pts):
        out, acc = [], 0.0
        for i, (la, lo, _) in enumerate(pts):
            if i:
                pla, plo, _ = pts[i - 1]
                dy = (la - pla) * 110540.0
                dx = (lo - plo) * 111320.0 * math.cos(math.radians(la))
                acc += (dx * dx + dy * dy) ** 0.5
            out.append((la, lo, acc))
        pts = out
    one = pts
    for _ in range(laps - 1):
        base = pts[-1][2]
        pts = pts + [(la, lo, base + d) for la, lo, d in one[1:]]
    return pts


def _project(pts, lat, lon, lo=0, hi=None):
    """(distance m, along-course m) of the closest point on pts[lo:hi]."""
    import math
    kx = 111320.0 * math.cos(math.radians(pts[0][0]))
    x, y = lon * kx, lat * 110540.0
    best = (float("inf"), 0.0)
    hi = len(pts) - 1 if hi is None else min(hi, len(pts) - 1)
    for j in range(lo, hi):
        ax, ay = pts[j][1] * kx, pts[j][0] * 110540.0
        bx, by = pts[j + 1][1] * kx, pts[j + 1][0] * 110540.0
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        u = 0.0 if L2 == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / L2))
        d = math.hypot(x - ax - u * dx, y - ay - u * dy)
        if d < best[0]:
            best = (d, pts[j][2] + u * (pts[j + 1][2] - pts[j][2]))
    return best


def _cut(pts, s0, s1):
    """Points of pts between along-course s0 and s1, interpolating the ends."""
    def at(sv):
        for j in range(len(pts) - 1):
            if pts[j][2] <= sv <= pts[j + 1][2]:
                a, b = pts[j], pts[j + 1]
                u = 0.0 if b[2] == a[2] else (sv - a[2]) / (b[2] - a[2])
                return (a[0] + u * (b[0] - a[0]), a[1] + u * (b[1] - a[1]), sv)
        return pts[-1] if sv >= pts[-1][2] else pts[0]
    mid = [p for p in pts if s0 < p[2] < s1]
    return [at(s0)] + mid + [at(s1)]


def _point_at(pts, sv):
    j = max(0, min(len(pts) - 2, __import__("bisect").bisect_right([p[2] for p in pts], sv) - 1))
    a, b = pts[j], pts[j + 1]
    u = 0.0 if b[2] == a[2] else max(0.0, min(1.0, (sv - a[2]) / (b[2] - a[2])))
    return a[0] + u * (b[0] - a[0]), a[1] + u * (b[1] - a[1])


def _best_start(lap, closed, track):
    """Along-course start that best explains the run's first kilometre: for
    each candidate, compare each fix with the course point that far along.
    Beats nearest-point matching where the route passes the start twice."""
    import math
    L = lap[-1][2]
    kx = 111320.0 * math.cos(math.radians(lap[0][0]))
    two = lap + [(la, lo, d + L) for la, lo, d in lap[1:]] if closed else lap
    best = (float("inf"), 0.0)
    for c in range(0, int(L), 5):
        err = 0.0
        for la, lo, g in track:
            pla, plo = _point_at(two, c + g)
            err += math.hypot((la - pla) * 110540.0, (lo - plo) * kx)
        if err < best[0]:
            best = (err, float(c))
    return best[1]


def fit_course_to_run(lap, laps, track):
    """A race course from a drawn route: for a closed loop, rotate it to begin
    where the run started, lay `laps` laps, and finish where the run ended
    (which may be part-way into one more lap, or off the loop: the run's own
    track is added from where it left the route). Open routes are trimmed to
    the run's start and end. track: [(lat, lon, gps m)] of the run. The start
    is assumed to be on the route."""
    L = lap[-1][2]
    closed = _project([lap[-1], lap[-1]], lap[0][0], lap[0][1])[0] < 30.0
    first_km = [p for p in track if p[2] <= 1000.0][::10]
    s0 = _best_start(lap, closed, first_km)
    if not closed:
        s1 = _project(lap, *track[-1][:2])[1]
        seg = _cut(lap, s0, s1)
        return [(la, lo, d - s0) for la, lo, d in seg]
    rot = _cut(lap, s0, L) + [(la, lo, d + L) for la, lo, d in _cut(lap, 0.0, s0)[1:]]
    rot = [(la, lo, d - s0) for la, lo, d in rot]
    many = rot
    for _ in range(laps):
        base = many[-1][2]
        many = many + [(la, lo, base + d) for la, lo, d in rot[1:]]
    # Finish: closest point to the run's end within the final lap and a bit.
    lo_i = next(i for i, p in enumerate(many) if p[2] >= (laps - 0.5) * L)
    # The finish may be off the drawn route (a finish chute): walk back from
    # the run's end to where it was last on the route, finish the route
    # there and add the run's own track from that point.
    j = len(track) - 1
    while j > 0:
        off, s_j = _project(many, track[j][0], track[j][1], lo=lo_i)
        if off <= 15.0:
            break
        j -= 1
    course = _cut(many, 0.0, s_j)
    base, g0 = course[-1][2], track[j][2]
    course += [(la, lo, base + g - g0) for la, lo, g in track[j + 1:] if g > g0]
    return course


def write_gpx(pts, path, name):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<gpx version="1.1" creator="CourseRun replay.py" xmlns="http://www.topografix.com/GPX/1/1">\n'
                 f' <trk>\n  <name>{name}</name>\n  <trkseg>\n')
        for la, lo, _ in pts:
            fh.write(f'   <trkpt lat="{la:.6f}" lon="{lo:.6f}"/>\n')
        fh.write("  </trkseg>\n </trk>\n</gpx>\n")


# ---- FIT input ---------------------------------------------------------------

def load(path):
    f = fitparse.FitFile(path)
    rows = lambda name: [{x.name: x.value for x in m.fields} for m in f.get_messages(name)]
    records = [r for r in rows("record") if r.get("timestamp") is not None]
    steps = {s.get("message_index"): s for s in rows("workout_step")}
    laps = rows("lap")
    events = rows("event")
    workout = rows("workout")
    profile = rows("user_profile")
    return records, steps, laps, events, workout, profile


def timer_seconds(records, events):
    """Timer time (s) at each record, from timer start/stop events."""
    marks = sorted((e["timestamp"], e.get("event_type")) for e in events
                   if e.get("event") == "timer" and e.get("timestamp") is not None)
    out, running, acc, since = [], False, 0.0, None
    mi = 0
    for r in records:
        ts = r["timestamp"]
        while mi < len(marks) and marks[mi][0] <= ts:
            mt, kind = marks[mi]
            if kind == "start" and not running:
                running, since = True, mt
            elif kind in ("stop", "stop_all", "stop_disable", "stop_disable_all") and running:
                acc += (mt - since).total_seconds()
                running = False
            mi += 1
        cur = acc + ((ts - since).total_seconds() if running else 0.0)
        out.append(cur)
    return out


def step_label(step):
    inten = step.get("intensity")
    if isinstance(inten, int):
        inten = INTENSITY.get(inten, str(inten))
    return {"rest": "REST", "recovery": "RECOVERY", "warmup": "WARM UP",
            "cooldown": "COOL DOWN"}.get(inten, (step.get("wkt_step_name") or inten or "").upper()), inten


def fmt_pace(sec_per_unit):
    if sec_per_unit is None or sec_per_unit <= 0 or sec_per_unit > 5999:
        return "--:--"
    s = int(round(sec_per_unit))
    return f"{s // 60}:{s % 60:02d}"


def fmt_timer(sec):
    s = int(sec)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def pace_from_speed(v, unit):
    return fmt_pace(unit / v) if v and v > 0 else "--:--"


# ---- replay ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fit")
    ap.add_argument("--legacy", action="store_true", help="v0.2.0 logic: speed targets always /1000, no settle period")
    ap.add_argument("--target-units", choices=["mmps", "mps"], default="mmps",
                    help="what getCurrentWorkoutStep() hands the field for speed targets (default mmps)")
    ap.add_argument("--settle", type=int, default=30, help="settle seconds at each step start (default 30)")
    ap.add_argument("--smooth", type=int, default=30, help="smoothing seconds setting (default 30)")
    ap.add_argument("--course", help="the course (.fit from Garmin Connect, or .gpx): replays CourseTracker too")
    ap.add_argument("--laps", type=int, default=1, help="repeat the course this many times (lapped race, one-lap file)")
    ap.add_argument("--fit-to-run", action="store_true",
                    help="cut the course to start/finish where the run did (a looped route drawn from elsewhere)")
    ap.add_argument("--write-course", help="write the course actually used (after --laps/--fit-to-run) as GPX")
    ap.add_argument("--goal", help="goal pace setting, m:ss per mile (per km with --km); used when no workout target")
    ap.add_argument("--tol", type=float, default=10.0, help="goal tolerance setting, seconds (default 10)")
    ap.add_argument("--official", type=float, default=0.0, help="official course length setting, in display units")
    ap.add_argument("--distance", choices=["recorded", "sim", "gps"],
                    help="distance driving the pace model (default: sim with --course, else recorded, else gps)")
    ap.add_argument("--gps", action="store_true", help="same as --distance gps")
    ap.add_argument("--km", action="store_true", help="paces per km")
    ap.add_argument("--csv", help="write the per-second timeline here")
    ap.add_argument("--changes", action="store_true", help="print every band status change")
    a = ap.parse_args()

    settle_ms = 0 if a.legacy else a.settle * 1000
    unit = M_PER_KM if a.km else M_PER_MI
    records, steps, laps, events, workout, profile = load(a.fit)
    if not records:
        sys.exit("no records")
    timer = timer_seconds(records, events)

    # Course distance as the field recorded it (developer field, mi or km).
    has_course = any(r.get("course_dist") is not None for r in records)
    course_unit = M_PER_MI
    if has_course and profile and profile[0].get("dist_setting") == "metric":
        course_unit = M_PER_KM
    source = "gps" if a.gps else (a.distance or ("sim" if a.course else ("recorded" if has_course else "gps")))
    if source == "recorded" and not has_course:
        sys.exit("no recorded course_dist in this file; use --course or --gps")
    if source == "sim" and not a.course:
        sys.exit("--distance sim needs --course")
    src = {"gps": "GPS distance", "recorded": "recorded course distance",
           "sim": "simulated CourseTracker on the course"}[source]

    # CourseTracker replay: distanceToDestination simulated from the course.
    sim = None
    if a.course:
        k = 180.0 / 2 ** 31
        if a.fit_to_run:
            track = [(r["position_lat"] * k, r["position_long"] * k, float(r.get("distance") or 0.0))
                     for r in records if r.get("position_lat") is not None]
            cpts = fit_course_to_run(load_course(a.course), a.laps, track)
        else:
            cpts = load_course(a.course, a.laps)
        if a.write_course:
            write_gpx(cpts, a.write_course, "CourseRun course")
            print(f"course written -> {a.write_course}")
        matcher = CourseMatcher(cpts)
        trk = CourseTracker(a.official * unit)
        k = 180.0 / 2 ** 31
        first = next((r for r in records if r.get("position_lat") is not None), None)
        if first:
            trk.preview(matcher.dtd_before_start(first["position_lat"] * k, first["position_long"] * k))
        sim, modes, prev_t, prev_g, offs = [], {0: 0, 1: 0, 2: 0}, -1.0, 0.0, []
        for i, r in enumerate(records):
            if timer[i] > 0 and timer[i] != prev_t:
                dtd = None
                g = float(r.get("distance") or 0.0)
                if r.get("position_lat") is not None:
                    dtd = matcher.dtd(r["position_lat"] * k, r["position_long"] * k, max(0.0, g - prev_g))
                prev_g = g
                was = trk.mode
                trk.update(float(r.get("distance") or 0.0), dtd)
                modes[trk.mode] += 1
                if trk.mode == CourseTracker.OFF and was != CourseTracker.OFF:
                    offs.append([timer[i], g, None, None])
                elif was == CourseTracker.OFF and trk.mode != CourseTracker.OFF:
                    offs[-1][2:] = [timer[i], g]
            prev_t = timer[i]
            sim.append(trk.course_dist)
        print(f"course {a.course}{' x' + str(a.laps) if a.laps > 1 else ''}: {matcher.length / unit:.3f} {'km' if a.km else 'mi'} ({matcher.length:.0f} m), "
              f"{len(cpts)} points")
        print(f"  tracker: learned length {trk.length:.0f} m, final {trk.course_dist / unit:.3f}, "
              f"seconds on course {modes[1]}, off course {modes[2]}, GPS-only {modes[0]}")
        for t_on, g_on, t_off, g_off in offs:
            t_off = t_off if t_off is not None else timer[-1]
            g_off = g_off if g_off is not None else float(records[-1].get("distance") or 0.0)
            print(f"  OFF COURSE at {fmt_timer(t_on)} ({g_on / unit:.2f} {'km' if a.km else 'mi'} GPS) "
                  f"for {fmt_timer(t_off - t_on)}, {g_off - g_on:.0f} m")
        if has_course:
            diffs = [sim[i] - float(r["course_dist"]) * course_unit for i, r in enumerate(records)
                     if r.get("course_dist") is not None]
            print(f"  sim vs recorded course_dist: end {diffs[-1]:+.0f} m, worst {max(diffs, key=abs):+.0f} m")

    # Which workout step is active at each moment: laps carry wkt_step_index.
    lap_marks = sorted((l["start_time"], l.get("wkt_step_index")) for l in laps if l.get("start_time"))
    lap_starts = [st for st, _ in lap_marks]

    goal_speed = 0.0
    if a.goal:
        mm, ss = a.goal.split(":")
        goal_sec = int(mm) * 60 + float(ss)
        goal_speed = unit / goal_sec
        goal_tol = a.tol / goal_sec

    def step_at(ts):
        idx = None
        for st, si in lap_marks:
            if st <= ts:
                idx = si
            else:
                break
        return idx

    buf = PaceBuffer()
    gps_buf = PaceBuffer(64)
    tgt = WorkoutTarget(legacy=a.legacy)
    cur_step = "unset"
    step_start_ms = 0
    last_alert_status, last_alert_ms = NONE, -100000
    timeline = []
    seg = []          # per-step summaries
    last_t = -1

    def new_seg(idx, t_ms, d, label=None):
        if label:
            inten, rng = None, ""
        elif idx is None:
            label, inten, rng = ("NO WORKOUT" if not steps else "WORKOUT DONE"), None, ""
        else:
            st = steps.get(idx, {})
            label, inten = step_label(st)
            rng = ""
        seg.append({"step": idx, "label": label, "inten": inten, "t0": t_ms, "d0": d,
                    "count": {NONE: 0, ON: 0, FAST: 0, SLOW: 0}, "alerts": 0,
                    "native": {"high": 0, "low": 0}, "range": rng, "agree": 0, "rec": 0})

    for i, r in enumerate(records):
        t_ms = int(round(timer[i] * 1000))
        if t_ms == last_t:
            continue
        running = t_ms > 0
        last_t = t_ms
        if source == "gps":
            d = float(r.get("distance") or 0.0)
        elif source == "sim":
            d = sim[i]
        else:
            cd = r.get("course_dist")
            d = float(cd) * course_unit if cd is not None else (timeline[-1]["dist"] if timeline else 0.0)
        hr = r.get("heart_rate")

        si = step_at(r["timestamp"])
        if not steps:
            # No workout: report per lap; the goal target never changes.
            lap_no = sum(1 for st in lap_starts if st <= r["timestamp"])
            if lap_no != cur_step:
                if cur_step == "unset" and goal_speed > 0:
                    tgt.kind = "pace"
                    tgt.low = goal_speed / (1 + goal_tol)
                    tgt.high = goal_speed / (1 - goal_tol)
                tgt.rest = False
                cur_step = lap_no
                new_seg(None, t_ms, d, label=f"LAP {lap_no}")
                if tgt.kind == "pace":
                    seg[-1]["range"] = f"{pace_from_speed(tgt.high, unit)}-{pace_from_speed(tgt.low, unit)}"
        elif si != cur_step:
            # onWorkoutStepComplete -> refresh(); settle period restarts.
            cur_step = si
            step_start_ms = t_ms
            tgt.kind = None
            rest = False
            if si is not None and si in steps:
                st = steps[si]
                _, inten = step_label(st)
                rest = inten in ("rest", "recovery")
                tt = st.get("target_type")
                if tt == "speed":
                    lo = st.get("custom_target_speed_low") or 0.0
                    hi = st.get("custom_target_speed_high") or 0.0
                    if a.target_units == "mmps":
                        lo, hi = int(round(lo * 1000)), int(round(hi * 1000))
                    tgt.set_from("speed", lo, hi)
                elif tt == "heart_rate":
                    tgt.set_from("heart_rate", st.get("custom_target_heart_rate_low") or 0,
                                 st.get("custom_target_heart_rate_high") or 0)
            tgt.rest = rest
            new_seg(si, t_ms, d)
            s = seg[-1]
            if tgt.kind == "pace":
                fast = "open" if tgt.high >= tgt.OPEN_HIGH else pace_from_speed(tgt.high, unit)
                slow = "open" if tgt.low <= 0 else pace_from_speed(tgt.low, unit)
                s["range"] = f"{fast}-{slow}"
                s["lo"], s["hi"] = tgt.low, tgt.high
            elif tgt.kind == "hr":
                s["range"] = f"{tgt.low:.0f}-{tgt.high:.0f} bpm"

        g_now = float(r.get("distance") or 0.0)
        if running:
            buf.add(t_ms, d)
            gps_buf.add(t_ms, g_now)
        if a.legacy:
            speed = buf.smoothed_speed(t_ms, d, a.smooth * 1000) if running else None
        else:
            # currentSpeed(): GPS rate scaled by the run's course/GPS ratio.
            speed = gps_buf.smoothed_speed(t_ms, g_now, a.smooth * 1000) if running else None
            if speed is not None and g_now > 1000.0 and source != "gps":
                speed *= min(1.05, max(0.95, d / g_now))
        prev = tgt.status
        if settle_ms and t_ms - step_start_ms < settle_ms:
            tgt.status = NONE
            status = NONE
        else:
            status = tgt.evaluate(speed, hr)
        shown = NONE if getattr(tgt, "rest", False) or tgt.kind is None else status

        s = seg[-1]
        s["count"][shown] += 1
        rec_band = r.get("band_status")
        if rec_band is not None:
            # What the watch's band actually showed (v0.3.0+).
            s["rec"] += 1
            s["agree"] += int(rec_band == status)
        s["t1"], s["d1"] = t_ms, d
        if running and status != prev and status in (FAST, SLOW) and not getattr(tgt, "rest", False):
            # maybeAlert() with alerts=always; goal-only mode would skip workouts.
            if status != last_alert_status and t_ms - last_alert_ms >= 15000:
                s["alerts"] += 1
                last_alert_status, last_alert_ms = status, t_ms
        elif status not in (FAST, SLOW):
            last_alert_status = status

        gps_v = r.get("enhanced_speed")
        timeline.append({"t": t_ms / 1000.0, "step": si, "dist": d, "gps_dist": r.get("distance"),
                         "sim": sim[i] if sim else None, "recorded": (float(r["course_dist"]) * course_unit
                                                                      if r.get("course_dist") is not None else None),
                         "speed": speed, "gps_speed": gps_v, "hr": hr, "status": STATUS_NAME[shown]})
        if a.changes and len(timeline) > 1 and timeline[-2]["status"] != timeline[-1]["status"]:
            print(f"  {fmt_pace(t_ms / 1000)}  {STATUS_NAME[shown]:9s}  smoothed {pace_from_speed(speed, unit)}")

    # Native watch alerts (speed_high_alert = it told you to slow down).
    t0 = records[0]["timestamp"]
    for e in events:
        if e.get("event_type") != "start" or e.get("event") not in ("speed_high_alert", "speed_low_alert"):
            continue
        si = step_at(e["timestamp"])
        for s in reversed(seg):
            if s["step"] == si and (e["timestamp"] - t0).total_seconds() * 1000 >= s["t0"] - 1000:
                s["native"]["high" if e["event"] == "speed_high_alert" else "low"] += 1
                break

    mode = "v0.2.0 (legacy)" if a.legacy else f"current, settle {a.settle}s"
    print(f"{a.fit}\n  logic: {mode}; targets as {a.target_units}; distance: {src}; smoothing {a.smooth}s")
    if workout:
        print(f"  workout: {workout[0].get('wkt_name')}")
    if has_course:
        last = records[-1]
        g, c = float(last.get("distance") or 0), float(last.get("course_dist") or 0) * course_unit
        print(f"  final: GPS {g / unit:.3f}, course {c / unit:.3f} ({c - g:+.0f} m)")
    u = "km" if a.km else "mi"
    rec = any(s["rec"] for s in seg)
    print(f"\n{'step':12s} {'time':>6s} {'target /' + u:>13s} {'actual':>7s}  {'ON':>4s} {'SLOW DN':>7s} {'SPEED UP':>8s} {'--':>4s}  alerts*  native hi/lo"
          + ("  match" if rec else ""))
    for s in seg:
        dt = (s.get("t1", s["t0"]) - s["t0"]) / 1000.0
        dd = s.get("d1", s["d0"]) - s["d0"]
        act = fmt_pace(dt / dd * unit) if dd > 10 else "--:--"
        c = s["count"]
        print(f"{s['label'][:12]:12s} {fmt_pace(dt):>6s} {s['range']:>13s} {act:>7s}  {c[ON]:4d} {c[FAST]:7d} {c[SLOW]:8d} {c[NONE]:4d}  {s['alerts']:7d}  {s['native']['high']:>8d}/{s['native']['low']}"
              + (f"  {100 * s['agree'] // s['rec']:4d}%" if s["rec"] else ""))
    print("  seconds in each band state; *alerts if set to Always; native = the Run app's own pace alerts")

    # Laps: the recorded lap_course_dist should restart at every lap.
    if any(l.get("lap_course_dist") is not None for l in laps):
        print("\nlap  GPS " + u + "   recorded lap_course_dist")
        for i, l in enumerate(laps):
            print(f"{i + 1:3d}  {float(l.get('total_distance') or 0) / unit:6.3f}   {l.get('lap_course_dist') or 0:6.3f}")

    # Per course mile/km: when the field's split flash would fire, what the
    # watch's own distance said then, and the goal gap (goalLine()).
    if source != "gps":
        print(f"\n{u:>4s}  {'time':>7s}  {'split':>5s}  {'watch ' + u:>8s}  {'watch ahead':>11s}" + ("  vs goal" if goal_speed else ""))
        n, prev_t = 1, 0.0
        for row in timeline:
            while row["dist"] >= n * unit:
                g = float(row["gps_dist"] or 0)
                line = (f"{n:4d}  {fmt_timer(row['t']):>7s}  {fmt_pace(row['t'] - prev_t):>5s}  {g / unit:8.2f}"
                        f"  {g - n * unit:+9.0f} m")
                if goal_speed:
                    gap = row["t"] - n * unit / goal_speed
                    line += f"  {'BEHIND' if gap > 0 else 'AHEAD'} {fmt_pace(abs(gap))}"
                print(line)
                prev_t = row["t"]
                n += 1
        end = timeline[-1]
        g = float(end["gps_dist"] or 0)
        print(f"end   {fmt_timer(end['t']):>7s}         course {end['dist'] / unit:.3f}, watch {g / unit:.3f} {u}")

    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(timeline[0].keys()))
            w.writeheader()
            w.writerows(timeline)
        print(f"\ntimeline -> {a.csv}")


if __name__ == "__main__":
    main()
