#!/usr/bin/env python3
"""Replay a recorded run through CourseRun's logic and report what the field
would have shown.

    python tools/replay.py run.fit                          # workout or goal run
    python tools/replay.py run.fit --goal 8:55              # goal-pace mode
    python tools/replay.py run.fit --course COURSE.fit      # also replay CourseTracker
    python tools/replay.py half.fit --course lap.gpx --laps 3 --fit-to-run \\
        --official 13.1094 --goal 8:55 --write-course race.gpx
    python tools/replay.py run.fit --csv out.csv --changes

Input is the activity FIT file (Garmin Connect > Export Original): timer
time, GPS distance, heart rate, the workout steps with the laps that mark step
changes and, when CourseRun was on the watch, its own recorded course distance
(`course_dist`) and band status (`band_status`, from v0.3.0).

distanceToDestination isn't in the FIT file. With --course it is simulated by
projecting each GPS fix onto the course (CourseMatcher) and CourseTracker is
replayed on it; without a course the pace model runs on the recorded
course_dist, or GPS distance if there is none. The models below are ports of
source/*.mc and must be kept in step with them.

Not replayed: heart-rate zone targets (zone numbers need the watch's zone
table); % of max HR targets use the FIT file's max HR when present.

Needs: pip install fitparse
"""
import argparse
import bisect
import csv
import math
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

try:
    import fitparse
except ImportError:
    sys.exit("needs fitparse: pip install fitparse")

M_PER_MI = 1609.344
M_PER_KM = 1000.0
SEMI_TO_DEG = 180.0 / 2 ** 31
M_PER_DEG_LAT = 110540.0
M_PER_DEG_LON_EQ = 111320.0

NONE, ON, FAST, SLOW = 0, 1, 2, 3
STATUS_NAME = {NONE: "--", ON: "ON PACE", FAST: "SLOW DOWN", SLOW: "SPEED UP"}

# FIT workout_step intensity (also Activity.WORKOUT_INTENSITY_*).
INTENSITY = {0: "active", 1: "rest", 2: "warmup", 3: "cooldown", 4: "recovery", 5: "interval", 6: "other"}
STEP_LABEL = {"rest": "REST", "recovery": "RECOVERY", "warmup": "WARM UP", "cooldown": "COOL DOWN"}

SETTLE_MS = 30000          # CourseRunField.SETTLE_MS
ALERT_GAP_MS = 15000       # CourseRunField.ALERT_GAP_MS


# ---- ports of the Monkey C models -------------------------------------------

class PaceBuffer:
    """source/PaceBuffer.mc: (timer ms, distance m) samples every interval."""

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
            del self.t[0], self.d[0]

    def distance_at_time(self, t):
        if not self.t or t < self.t[0]:
            return None
        i = bisect.bisect_right(self.t, t) - 1
        if i == len(self.t) - 1 or self.t[i + 1] - self.t[i] <= 0:
            return float(self.d[i])
        return self.d[i] + (self.d[i + 1] - self.d[i]) * (t - self.t[i]) / (self.t[i + 1] - self.t[i])

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
    """source/WorkoutTarget.mc: target parsing, goal fallback, hysteresis."""
    OPEN_HIGH = 99.0
    MMPS_MIN = 100.0
    HYST = 0.015

    def __init__(self):
        self.kind = None          # "pace" / "hr" / None
        self.source = None        # "workout" / "goal" / None
        self.low = self.high = 0.0
        self.rest = False
        self.label = ""
        self.intensity = ""       # report label when the step has no name
        self.status = NONE
        self.goal_speed = 0.0
        self.goal_tol = 0.0

    def set_goal(self, sec_per_unit, unit_m, tol_sec):
        if sec_per_unit <= 0:
            self.goal_speed = 0.0
            return
        self.goal_speed = unit_m / sec_per_unit
        self.goal_tol = tol_sec / sec_per_unit if tol_sec > 0 else 0.0

    def apply_goal(self):
        if self.kind is not None or self.goal_speed <= 0 or self.rest:
            return
        self.low = self.goal_speed / (1 + self.goal_tol)
        self.high = self.goal_speed / (1 - self.goal_tol)
        self.kind, self.source = "pace", "goal"

    def set_step(self, step, max_hr, mmps):
        """refresh() for one FIT workout step (None: no workout running).
        mmps: speed targets handed over as mm/s Numbers, else m/s Floats."""
        self.kind = self.source = None
        self.rest, self.label, self.intensity = False, "", ""
        if step is not None:
            inten = step.get("intensity")
            inten = INTENSITY.get(inten, str(inten)) if isinstance(inten, int) else inten
            self.rest = inten in ("rest", "recovery")
            name = step.get("wkt_step_name") or ""
            self.label = STEP_LABEL.get(inten, name.upper() if 0 < len(name) <= 12 else "")
            self.intensity = (inten or "").upper()
            tt = step.get("target_type")
            if tt == "speed":
                lo = step.get("custom_target_speed_low") or 0.0
                hi = step.get("custom_target_speed_high") or 0.0
                if mmps:
                    lo, hi = round(lo * 1000), round(hi * 1000)
                self.set_from("speed", lo, hi, max_hr)
            elif tt == "heart_rate":
                self.set_from("heart_rate", step.get("custom_target_heart_rate_low") or 0,
                              step.get("custom_target_heart_rate_high") or 0, max_hr)
            if self.kind is not None:
                self.source = "workout"
        self.apply_goal()

    def set_from(self, target_type, lo, hi, max_hr=None):
        self.kind = None
        fl, fh = float(lo), float(hi)
        if target_type == "speed":
            if fl <= 0 and fh <= 0:
                return
            a = fl / 1000.0 if fl >= self.MMPS_MIN else fl
            b = fh / 1000.0 if fh >= self.MMPS_MIN else fh
            if a > 0 and b > 0 and a > b:
                a, b = b, a
            self.low = a if a > 0 else 0.0
            self.high = b if b > 0 else self.OPEN_HIGH
            self.kind = "pace"
        elif target_type == "heart_rate":
            if fl > 100 or fh > 100:
                self.low = fl - 100 if fl > 100 else fl
                self.high = fh - 100 if fh > 100 else fh
            elif max_hr and fl > 0 and fh > 0 and not (fl == fh and 1 <= fl <= 5):
                self.low, self.high = max_hr * fl / 100.0, max_hr * fh / 100.0
            else:
                return   # zone targets: not replayed (see the module docstring)
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
        elif v > hi * (1 + h):
            nxt = FAST
        elif v < lo * (1 - h):
            nxt = SLOW
        self.status = nxt
        return nxt


class CourseTracker:
    """source/CourseTracker.mc"""
    GPS, COURSE, OFF = 0, 1, 2
    RELOCK_MIN_M = 500.0
    STALL_SECS = 20
    STALL_GPS_M = 50.0
    RESCALE_TOL = 0.05
    START_SNAP_M = 100.0
    CATCHUP_M = 400.0
    LEAP_M = 400.0

    def __init__(self, official=0.0):
        self.course_dist, self.mode, self.mismatch = 0.0, self.GPS, False
        self.length, self.official = None, official
        self.last_gps, self.last_cand = None, None
        self.stall_ticks, self.stall_gps = 0, 0.0

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
        delta = max(0.0, gps - self.last_gps) if self.last_gps is not None else 0.0
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


def parse_pace(text):
    """Fmt.parsePace: "m:ss" or decimal minutes; 0 if invalid or outside 2:00-30:00."""
    s = (text or "").strip()
    if ":" in s:
        parts = s.split(":")
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit() or int(parts[1]) >= 60:
            return 0.0
        sec = int(parts[0]) * 60.0 + int(parts[1])
    else:
        if not s or s.count(".") > 1 or not s.replace(".", "").isdigit():
            return 0.0
        sec = float(s) * 60.0
    return sec if 120.0 <= sec <= 1800.0 else 0.0


# ---- course geometry --------------------------------------------------------

class Plane:
    """Flat projection around a latitude, in metres."""

    def __init__(self, lat0):
        self.kx = M_PER_DEG_LON_EQ * math.cos(math.radians(lat0))

    def xy(self, lat, lon):
        return lon * self.kx, lat * M_PER_DEG_LAT

    def dist(self, a, b):
        (ax, ay), (bx, by) = self.xy(a[0], a[1]), self.xy(b[0], b[1])
        return math.hypot(ax - bx, ay - by)


def project_segment(p, a, b):
    """(distance from p to segment ab, fraction along it); points as (x, y)."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    l2 = dx * dx + dy * dy
    u = 0.0 if l2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2))
    return math.hypot(p[0] - a[0] - u * dx, p[1] - a[1] - u * dy), u


class Course:
    """Course points [(lat, lon, along-course m)] with projection helpers."""

    def __init__(self, pts):
        self.pts = pts
        self.plane = Plane(pts[0][0])
        self.xy = [self.plane.xy(la, lo) for la, lo, _ in pts]
        self.s = [p[2] for p in pts]
        self.length = self.s[-1]

    def index_at(self, dist):
        return max(0, min(len(self.s) - 1, bisect.bisect_left(self.s, dist)))

    def candidates(self, lat, lon, lo=0, hi=None):
        """(distance off, along-course m) on each segment from lo to hi."""
        p = self.plane.xy(lat, lon)
        hi = len(self.xy) - 1 if hi is None else min(hi + 1, len(self.xy) - 1)
        out = []
        for j in range(lo, hi):
            d, u = project_segment(p, self.xy[j], self.xy[j + 1])
            out.append((d, self.s[j] + u * (self.s[j + 1] - self.s[j])))
        return out

    def nearest(self, lat, lon, lo=0):
        c = self.candidates(lat, lon, lo)
        return min(c) if c else (float("inf"), 0.0)

    def point_at(self, sv):
        j = max(0, min(len(self.pts) - 2, bisect.bisect_right(self.s, sv) - 1))
        a, b = self.pts[j], self.pts[j + 1]
        u = 0.0 if b[2] == a[2] else max(0.0, min(1.0, (sv - a[2]) / (b[2] - a[2])))
        return a[0] + u * (b[0] - a[0]), a[1] + u * (b[1] - a[1]), sv

    def cut(self, s0, s1):
        """Points between along-course s0 and s1, ends interpolated."""
        return [self.point_at(s0)] + [p for p in self.pts if s0 < p[2] < s1] + [self.point_at(s1)]


class CourseMatcher:
    """Stand-in for the watch's distanceToDestination: project each fix onto
    the course, searching from the last match. Where the route doubles back
    (out-and-back legs, laps) several stretches are equally close, so of
    those near the best it takes the one closest to the expected progress
    (last match + GPS distance moved). Garmin's algorithm isn't published;
    against a real FR965 run this one was about twice as noisy."""
    LOOK_BACK_M, LOOK_AHEAD_M, OFF_COURSE_M = 50.0, 400.0, 40.0

    def __init__(self, course):
        self.c = course
        self.length = course.length
        self.s_cur = None

    def dtd(self, lat, lon, moved=0.0):
        c = self.c
        if self.s_cur is None:
            lo, hi, expect = 0, c.index_at(min(500.0, self.length / 4)), 0.0
        else:
            # Back one point: on long straight segments the one we're on can
            # start well before s_cur - LOOK_BACK_M.
            lo = max(0, c.index_at(self.s_cur - self.LOOK_BACK_M) - 1)
            hi = c.index_at(self.s_cur + max(self.LOOK_AHEAD_M, moved * 3))
            expect = self.s_cur + moved
        cands = c.candidates(lat, lon, lo, hi)
        if not cands:
            return None
        best = min(x[0] for x in cands)
        if best > self.OFF_COURSE_M and self.s_cur is not None:
            return self.length - self.s_cur   # frozen while off course
        near = [x for x in cands if x[0] <= max(best + 10.0, 15.0)]
        self.s_cur = min(near, key=lambda x: abs(x[1] - expect))[1]
        return self.length - self.s_cur

    def dtd_before_start(self, lat, lon):
        """Before START: distance to the course start plus its length."""
        return self.length + self.c.plane.dist((lat, lon), self.c.pts[0])


def load_course(path, laps=1):
    """Course points [(lat, lon, along m)] from a course FIT or a GPX file,
    repeated `laps` times."""
    pts = []
    if path.lower().endswith(".gpx"):
        for el in ET.parse(path).getroot().iter():
            if el.tag.endswith(("trkpt", "rtept")):
                if el.get("lat") is None or el.get("lon") is None:
                    sys.exit(f"{path}: track point without lat/lon")
                pts.append((float(el.get("lat")), float(el.get("lon")), None))
    else:
        for m in fitparse.FitFile(path).get_messages("record"):
            v = {x.name: x.value for x in m.fields}
            if v.get("position_lat") is not None:
                pts.append((v["position_lat"] * SEMI_TO_DEG, v["position_long"] * SEMI_TO_DEG, v.get("distance")))
    if len(pts) < 2:
        sys.exit(f"{path}: fewer than two course points")
    if any(p[2] is None for p in pts):
        plane, acc, out = Plane(pts[0][0]), 0.0, []
        for i, p in enumerate(pts):
            acc += plane.dist(pts[i - 1], p) if i else 0.0
            out.append((p[0], p[1], acc))
        pts = out
    one = pts
    for _ in range(laps - 1):
        base = pts[-1][2]
        pts = pts + [(la, lo, base + d) for la, lo, d in one[1:]]
    return pts


def fit_course_to_run(lap_pts, laps, track):
    """A race course from a drawn route and the run on it.

    Closed loop: rotate it to begin where the run started (best fit over the
    first km, so a route that passes the start twice still lines up), lay
    `laps` laps in all, and finish where the run finished; if the finish is
    off the route (a finish chute), the run's own track is added from where
    it last was on the route. Open route: trimmed to the run's start and
    finish. The start is assumed to be on the route.
    track: [(lat, lon, GPS m)]."""
    lap = Course(lap_pts)
    L = lap.length
    closed = lap.plane.dist(lap_pts[0], lap_pts[-1]) < 30.0
    s0 = _best_start(lap_pts, closed, [p for p in track if p[2] <= 1000.0][::10])
    if not closed:
        s1 = lap.nearest(*track[-1][:2])[1]
        return [(la, lo, d - s0) for la, lo, d in lap.cut(s0, s1)]

    rot = lap.cut(s0, L) + [(la, lo, d + L) for la, lo, d in lap.cut(0.0, s0)[1:]]
    rot = [(la, lo, d - s0) for la, lo, d in rot]
    many = rot
    for _ in range(laps):              # one lap spare: the finish may be past the last
        base = many[-1][2]
        many = many + [(la, lo, base + d) for la, lo, d in rot[1:]]
    full = Course(many)
    lo_i = full.index_at((laps - 0.5) * L)
    for j in range(len(track) - 1, -1, -1):
        off, s_j = full.nearest(track[j][0], track[j][1], lo=lo_i)
        if off <= 15.0:
            break
    else:
        sys.exit("the run's finish never comes near the last lap of the course")
    course = full.cut(0.0, s_j)
    base, g0 = course[-1][2], track[j][2]
    return course + [(la, lo, base + g - g0) for la, lo, g in track[j + 1:] if g > g0]


def _best_start(lap_pts, closed, track):
    """Along-course start that best explains the run's first kilometre."""
    L = lap_pts[-1][2]
    two = Course(lap_pts + [(la, lo, d + L) for la, lo, d in lap_pts[1:]] if closed else lap_pts)
    best = (float("inf"), 0.0)
    for c in range(0, int(L), 5):
        err = sum(two.plane.dist((la, lo), two.point_at(c + g)) for la, lo, g in track)
        best = min(best, (err, float(c)))
    return best[1]


def write_gpx(pts, path, name):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<gpx version="1.1" creator="CourseRun replay.py" xmlns="http://www.topografix.com/GPX/1/1">\n'
                 f' <trk>\n  <name>{escape(name)}</name>\n  <trkseg>\n')
        for la, lo, _ in pts:
            fh.write(f'   <trkpt lat="{la:.6f}" lon="{lo:.6f}"/>\n')
        fh.write("  </trkseg>\n </trk>\n</gpx>\n")


# ---- the run ----------------------------------------------------------------

class Run:
    """The activity FIT file, one entry per record."""

    def __init__(self, path):
        f = fitparse.FitFile(path)

        def rows(name):
            return [{x.name: x.value for x in m.fields} for m in f.get_messages(name)]

        self.path = path
        self.records = [r for r in rows("record") if r.get("timestamp") is not None]
        if not self.records:
            sys.exit(f"{path}: no records")
        self.steps = {s.get("message_index"): s for s in rows("workout_step")}
        self.laps = rows("lap")
        self.events = rows("event")
        workout = rows("workout")
        self.workout_name = workout[0].get("wkt_name") if workout else None
        profile = rows("user_profile")
        self.metric = bool(profile) and profile[0].get("dist_setting") == "metric"
        zones = rows("zones_target")
        self.max_hr = zones[0].get("max_heart_rate") if zones else None
        self.course_unit = M_PER_KM if self.metric else M_PER_MI   # unit course_dist is recorded in
        self.has_course_dist = any(r.get("course_dist") is not None for r in self.records)
        self.timer = self._timer_seconds()
        # GPS distance carried forward over records without one, as the
        # watch keeps its last elapsedDistance.
        self.gps, last = [], 0.0
        for r in self.records:
            last = float(r["distance"]) if r.get("distance") is not None else last
            self.gps.append(last)
        self.lap_marks = sorted((l["start_time"], l.get("wkt_step_index"))
                                for l in self.laps if l.get("start_time"))

    def _timer_seconds(self):
        marks = sorted((e["timestamp"], e.get("event_type")) for e in self.events
                       if e.get("event") == "timer" and e.get("timestamp") is not None)
        out, running, acc, since, mi = [], False, 0.0, None, 0
        for r in self.records:
            ts = r["timestamp"]
            while mi < len(marks) and marks[mi][0] <= ts:
                mt, kind = marks[mi]
                if kind == "start" and not running:
                    running, since = True, mt
                elif kind in ("stop", "stop_all", "stop_disable", "stop_disable_all") and running:
                    acc += (mt - since).total_seconds()
                    running = False
                mi += 1
            out.append(acc + ((ts - since).total_seconds() if running else 0.0))
        return out

    def recorded_course(self):
        """The field's recorded course distance (m) per record, carried forward."""
        out, last = [], 0.0
        for r in self.records:
            last = float(r["course_dist"]) * self.course_unit if r.get("course_dist") is not None else last
            out.append(last)
        return out

    def fixes(self):
        """(record index, lat, lon) for records with a position."""
        return [(i, r["position_lat"] * SEMI_TO_DEG, r["position_long"] * SEMI_TO_DEG)
                for i, r in enumerate(self.records) if r.get("position_lat") is not None]

    def lap_at(self, ts):
        """(lap number from 1, workout step index or None) at a time."""
        n, step = 0, None
        for st, si in self.lap_marks:
            if st > ts:
                break
            n, step = n + 1, si
        return n, step


# ---- replays ----------------------------------------------------------------

def simulate_course(run, course_pts, official_m, unit, unit_name):
    """Replay CourseTracker on simulated distanceToDestination. Returns
    (course distance, tracker mode) per record."""
    matcher = CourseMatcher(Course(course_pts))
    trk = CourseTracker(official_m)
    fixes = run.fixes()
    if fixes:
        trk.preview(matcher.dtd_before_start(fixes[0][1], fixes[0][2]))
    pos = {i: (la, lo) for i, la, lo in fixes}
    dist, modes, counts, offs = [], [], {0: 0, 1: 0, 2: 0}, []
    prev_t, prev_g = -1.0, 0.0
    for i in range(len(run.records)):
        t, g = run.timer[i], run.gps[i]
        if t > 0 and t != prev_t:
            dtd = matcher.dtd(*pos[i], max(0.0, g - prev_g)) if i in pos else None
            prev_g = g
            was = trk.mode
            trk.update(g, dtd)
            counts[trk.mode] += 1
            if trk.mode == CourseTracker.OFF and was != CourseTracker.OFF:
                offs.append([t, g, None, None])
            elif was == CourseTracker.OFF and trk.mode != CourseTracker.OFF:
                offs[-1][2:] = [t, g]
        prev_t = t
        dist.append(trk.course_dist)
        modes.append(trk.mode)

    print(f"course: {matcher.length / unit:.3f} {unit_name} ({matcher.length:.0f} m), {len(course_pts)} points")
    print(f"  tracker: learned length {trk.length or 0:.0f} m, final {trk.course_dist / unit:.3f} {unit_name}; "
          f"seconds on course {counts[1]}, off course {counts[2]}, GPS only {counts[0]}")
    for t_on, g_on, t_off, g_off in offs:
        t_off = run.timer[-1] if t_off is None else t_off
        g_off = run.gps[-1] if g_off is None else g_off
        print(f"  OFF COURSE at {fmt_timer(t_on)} ({g_on / unit:.2f} {unit_name} GPS) "
              f"for {fmt_timer(t_off - t_on)}, {g_off - g_on:.0f} m")
    if run.has_course_dist:
        rec = run.recorded_course()
        diffs = [dist[i] - rec[i] for i, r in enumerate(run.records) if r.get("course_dist") is not None]
        print(f"  sim vs recorded course_dist: end {diffs[-1]:+.0f} m, worst {max(diffs, key=abs):+.0f} m")
    return dist, modes


def replay_band(run, dist, modes, a, unit):
    """CourseRunField.compute() per record: step changes, settle, rest,
    evaluate on currentSpeed(), maybeAlert(). Returns (segments, timeline);
    segments are workout steps, or laps when there is no workout."""
    tgt = WorkoutTarget()
    tgt.set_goal(parse_pace(a.goal) if a.goal else 0.0, unit, a.tol)
    gps_buf = PaceBuffer(64)
    alerts = {"off": 0, "goal": 1, "always": 2}[a.alerts]
    by_lap = not run.steps

    segs, timeline = [], []
    cur_step, seg_key = object(), object()   # sentinels: differ from any value
    step_start, last_t = 0, -1
    last_alert_status, last_alert_ms = NONE, -100000

    for i, r in enumerate(run.records):
        t_ms = int(round(run.timer[i] * 1000))
        running = t_ms > 0 and last_t >= 0 and t_ms != last_t
        last_t = t_ms
        d, g = dist[i], run.gps[i]
        lap_no, si = run.lap_at(r["timestamp"])

        if si != cur_step:
            # onWorkoutStarted / onWorkoutStepComplete: refresh(), newStep().
            cur_step = si
            tgt.set_step(run.steps.get(si) if si is not None else None, run.max_hr, a.target_units == "mmps")
            tgt.status = NONE
            step_start = t_ms
        key = lap_no if by_lap else si
        if key != seg_key:
            seg_key = key
            label = (f"LAP {lap_no}" if by_lap
                     else tgt.label or tgt.intensity or ("WORKOUT DONE" if si is None else f"STEP {si + 1}"))
            segs.append(new_segment(label, tgt, t_ms, d, unit))

        if running:
            gps_buf.add(t_ms, g)
        speed = None
        if not running or tgt.rest or t_ms - step_start < SETTLE_MS:
            tgt.status = status = NONE
        else:
            # currentSpeed(): GPS rate x the run's course/GPS ratio while on course.
            speed = gps_buf.smoothed_speed(t_ms, g, a.smooth * 1000)
            if speed is not None and g > 1000.0 and modes[i] == CourseTracker.COURSE:
                speed *= min(1.05, max(0.95, d / g))
            status = tgt.evaluate(speed, r.get("heart_rate"))

        s = segs[-1]
        s["count"][status] += 1
        s["t1"], s["d1"] = t_ms, d
        if running and r.get("band_status") is not None:
            s["rec"] += 1
            s["agree"] += int(r["band_status"] == status)
        if running and not (alerts == 0 or (alerts == 1 and tgt.source != "goal")):
            if status not in (FAST, SLOW):
                last_alert_status = status
            elif status != last_alert_status and t_ms - last_alert_ms >= ALERT_GAP_MS:
                s["alerts"] += 1
                last_alert_status, last_alert_ms = status, t_ms

        timeline.append({"t": t_ms / 1000.0, "lap": lap_no, "step": si, "dist": d, "gps_dist": g,
                         "mode": modes[i], "speed": speed, "gps_speed": r.get("enhanced_speed"),
                         "hr": r.get("heart_rate"), "status": STATUS_NAME[status]})
        if a.changes and len(timeline) > 1 and timeline[-2]["status"] != timeline[-1]["status"]:
            print(f"  {fmt_timer(t_ms / 1000)}  {STATUS_NAME[status]:9s}  smoothed {pace_from_speed(speed, unit)}")
    return segs, timeline


def new_segment(label, tgt, t_ms, d, unit):
    rng = ""
    if tgt.kind == "pace":
        fast = "open" if tgt.high >= tgt.OPEN_HIGH else pace_from_speed(tgt.high, unit)
        slow = "open" if tgt.low <= 0 else pace_from_speed(tgt.low, unit)
        rng = f"{fast}-{slow}"
    elif tgt.kind == "hr":
        rng = f"{tgt.low:.0f}-{tgt.high:.0f} bpm"
    return {"label": label, "range": rng, "t0": t_ms, "d0": d, "t1": t_ms, "d1": d,
            "count": {NONE: 0, ON: 0, FAST: 0, SLOW: 0}, "alerts": 0, "rec": 0, "agree": 0}


# ---- reports ----------------------------------------------------------------

def fmt_pace(sec):
    if sec is None or sec <= 0 or sec > 5999:
        return "--:--"
    s = int(round(sec))
    return f"{s // 60}:{s % 60:02d}"


def fmt_timer(sec):
    s = int(sec)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def pace_from_speed(v, unit):
    return fmt_pace(unit / v) if v and v > 0 else "--:--"


def native_alerts(run, segs):
    """The Run app's own pace alerts per segment: (speed high = it said slow
    down, speed low)."""
    t0 = run.records[0]["timestamp"]
    starts = [s["t0"] for s in segs]
    out = [[0, 0] for _ in segs]
    for e in run.events:
        if e.get("event_type") == "start" and e.get("event") in ("speed_high_alert", "speed_low_alert"):
            k = max(0, bisect.bisect_right(starts, (e["timestamp"] - t0).total_seconds() * 1000) - 1)
            out[k][0 if e["event"] == "speed_high_alert" else 1] += 1
    return out


def report_segments(segs, run, a, unit, unit_name):
    rec = any(s["rec"] for s in segs)
    print(f"\n{'segment':12s} {'time':>6s} {'target /' + unit_name:>13s} {'actual':>7s}  {'ON':>4s} "
          f"{'SLOW DN':>7s} {'SPEED UP':>8s} {'--':>4s}  alerts  native hi/lo" + ("  match" if rec else ""))
    for s, (hi, lo) in zip(segs, native_alerts(run, segs)):
        dt, dd = (s["t1"] - s["t0"]) / 1000.0, s["d1"] - s["d0"]
        c = s["count"]
        actual = fmt_pace(dt / dd * unit) if dd > 10 else "--:--"
        print(f"{s['label'][:12]:12s} {fmt_pace(dt):>6s} {s['range']:>13s} {actual:>7s}  {c[ON]:4d} "
              f"{c[FAST]:7d} {c[SLOW]:8d} {c[NONE]:4d}  {s['alerts']:6d}  {hi:>8d}/{lo}"
              + (f"  {100 * s['agree'] // s['rec']:4d}%" if s["rec"] else ""))
    print(f"  seconds in each band state; alerts with the alerts setting '{a.alerts}'; "
          "native = the Run app's own pace alerts")


def report_miles(timeline, goal_speed, unit, unit_name):
    """Per course mile/km: when the split flash fires, the watch's own
    distance then, and the goal gap (goalLine())."""
    print(f"\n{unit_name:>4s}  {'time':>7s}  {'split':>5s}  {'watch':>7s}  {'watch ahead':>11s}"
          + ("  vs goal" if goal_speed else ""))
    n, prev_t = 1, 0.0
    for row in timeline:
        while row["dist"] >= n * unit:
            g = row["gps_dist"]
            line = (f"{n:4d}  {fmt_timer(row['t']):>7s}  {fmt_pace(row['t'] - prev_t):>5s}  {g / unit:7.2f}"
                    f"  {g - n * unit:+9.0f} m")
            if goal_speed:
                gap = row["t"] - n * unit / goal_speed
                line += f"  {'BEHIND' if gap > 0 else 'AHEAD'} {fmt_pace(abs(gap))}"
            print(line)
            prev_t, n = row["t"], n + 1
    end = timeline[-1]
    print(f"end   {fmt_timer(end['t']):>7s}         course {end['dist'] / unit:.3f}, "
          f"watch {end['gps_dist'] / unit:.3f} {unit_name}")


def report_laps(run, unit, unit_name):
    """The recorded lap_course_dist should restart at every lap."""
    if not any(l.get("lap_course_dist") is not None for l in run.laps):
        return
    print(f"\nlap  GPS {unit_name}  recorded lap_course_dist")
    for i, l in enumerate(run.laps):
        print(f"{i + 1:3d}  {float(l.get('total_distance') or 0) / unit:6.3f}  {l.get('lap_course_dist') or 0:6.3f}")


# ---- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fit", help="activity FIT file")
    ap.add_argument("--course", help="course (.fit from Garmin Connect, or .gpx): replays CourseTracker too")
    ap.add_argument("--laps", type=int, default=1, help="laps of the course in the race (one-lap route file)")
    ap.add_argument("--fit-to-run", action="store_true",
                    help="cut the course to start/finish where the run did (looped route drawn from elsewhere)")
    ap.add_argument("--write-course", help="write the course used (after --laps/--fit-to-run) as GPX")
    ap.add_argument("--official", type=float, default=0.0, help="official length setting, in distance units")
    ap.add_argument("--distance", choices=["recorded", "sim", "gps"],
                    help="distance for the pace model (default: sim with --course, else recorded, else gps)")
    ap.add_argument("--goal", help="goal pace setting, m:ss or decimal minutes per unit")
    ap.add_argument("--tol", type=float, default=10.0, help="goal tolerance setting, seconds (default 10)")
    ap.add_argument("--alerts", choices=["off", "goal", "always"], default="goal",
                    help="alerts setting (default goal)")
    ap.add_argument("--smooth", type=int, default=30, help="smoothing setting, seconds (default 30)")
    ap.add_argument("--units", choices=["mi", "km"], help="display units (default: the watch's, from the file)")
    ap.add_argument("--target-units", choices=["mmps", "mps"], default="mmps",
                    help="how getCurrentWorkoutStep() hands over speed targets (the field accepts both)")
    ap.add_argument("--csv", help="write the per-second timeline here")
    ap.add_argument("--changes", action="store_true", help="print every band status change")
    a = ap.parse_args()
    if not 5 <= a.smooth <= 120:
        ap.error("--smooth: the setting allows 5-120 s")
    if a.laps < 1:
        ap.error("--laps must be at least 1")
    if a.goal and not parse_pace(a.goal):
        ap.error(f"--goal {a.goal}: not a pace between 2:00 and 30:00")

    run = Run(a.fit)
    metric = run.metric if a.units is None else a.units == "km"
    unit, unit_name = (M_PER_KM, "km") if metric else (M_PER_MI, "mi")
    source = a.distance or ("sim" if a.course else ("recorded" if run.has_course_dist else "gps"))
    if source == "recorded" and not run.has_course_dist:
        sys.exit("no recorded course_dist in this file: use --course or --distance gps")
    if source == "sim" and not a.course:
        sys.exit("--distance sim needs --course")

    print(run.path)
    if run.workout_name:
        print(f"  workout: {run.workout_name}")
    if source == "gps":
        dist, modes = list(run.gps), [CourseTracker.GPS] * len(run.records)
    else:
        # Recorded course distance: the tracker mode isn't recorded; assume on course.
        dist, modes = (run.recorded_course() if run.has_course_dist else None), [CourseTracker.COURSE] * len(run.records)
    if a.course:
        if a.fit_to_run:
            pts = fit_course_to_run(load_course(a.course), a.laps,
                                    [(la, lo, run.gps[i]) for i, la, lo in run.fixes()])
        else:
            pts = load_course(a.course, a.laps)
        if a.write_course:
            write_gpx(pts, a.write_course, "CourseRun course")
            print(f"course written -> {a.write_course}")
        sim, sim_modes = simulate_course(run, pts, a.official * unit, unit, unit_name)
        if source == "sim":
            dist, modes = sim, sim_modes

    label = {"gps": "GPS distance", "recorded": "recorded course distance", "sim": "simulated course distance"}
    print(f"  pace model on {label[source]}; smoothing {a.smooth} s; targets as {a.target_units}")
    if run.has_course_dist:
        g, c = run.gps[-1], run.recorded_course()[-1]
        print(f"  recorded: GPS {g / unit:.3f}, course {c / unit:.3f} {unit_name} ({c - g:+.0f} m)")

    segs, timeline = replay_band(run, dist, modes, a, unit)
    report_segments(segs, run, a, unit, unit_name)
    if source != "gps":
        report_miles(timeline, unit / parse_pace(a.goal) if a.goal else 0.0, unit, unit_name)
    report_laps(run, unit, unit_name)
    if a.csv:
        with open(a.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(timeline[0].keys()))
            w.writeheader()
            w.writerows(timeline)
        print(f"\ntimeline -> {a.csv}")


if __name__ == "__main__":
    main()
