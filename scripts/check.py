#!/usr/bin/env python3
"""Static checks for the CourseRun repo. Runs in CI and locally (python scripts/check.py).

These do not need the Connect IQ SDK. They catch the mistakes that would
otherwise only show up on the watch: permission creep, secrets in the tree,
resource files that don't parse, FIT field ids that collide, settings without
strings, and unguarded calls into firmware-dependent APIs.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []


def err(msg):
    errors.append(msg)


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def walk(exts, subdirs=("source", "tests", "resources", "scripts", ".github")):
    for sub in subdirs:
        for dirpath, _, files in os.walk(os.path.join(ROOT, sub)):
            for fn in files:
                if fn.endswith(exts):
                    yield os.path.relpath(os.path.join(dirpath, fn), ROOT)


# 1. Manifest: only the permissions we document, and a datafield.
ALLOWED_PERMISSIONS = {"UserProfile", "FitContributor"}
manifest = ET.parse(os.path.join(ROOT, "manifest.xml")).getroot()
ns = {"iq": "http://www.garmin.com/xml/connectiq"}
app = manifest.find("iq:application", ns)
if app is None or app.get("type") != "datafield":
    err("manifest.xml: application type must be 'datafield'")
perms = {p.get("id") for p in manifest.findall(".//iq:uses-permission", ns)}
extra = perms - ALLOWED_PERMISSIONS
if extra:
    err(f"manifest.xml: unexpected permissions {sorted(extra)}; update SECURITY.md and this check if intended")

# 2. No network, positioning, or background APIs in source.
FORBIDDEN = {
    "Communications": "network access",
    "Toybox.Position": "raw GPS access",
    "Background": "background service",
    "makeWebRequest": "network access",
    "Toybox.Cryptography": "crypto (nothing here should need it)",
}
for path in walk((".mc",), ("source",)):
    text = read(path)
    for token, why in FORBIDDEN.items():
        if re.search(r"\b" + re.escape(token) + r"\b", text):
            err(f"{path}: uses {token} ({why})")

# 3. Secrets and keys never committed. Only git-tracked files count; the
#    developer key legitimately sits in the working tree, git-ignored.
import subprocess
try:
    tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
except Exception:
    tracked = []
    for dirpath, dirnames, files in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in (".git", "bin")]
        tracked += [os.path.relpath(os.path.join(dirpath, fn), ROOT) for fn in files]
for path in tracked:
    fn = os.path.basename(path)
    if fn.startswith("developer_key") or fn.endswith((".der", ".pem", ".p12", ".pfx")):
        err(f"{path}: signing key material must not be committed")
SECRET_PATTERNS = [
    (r"AKIA[0-9A-Z]{16}", "AWS access key"),
    (r"ghp_[A-Za-z0-9]{36}", "GitHub token"),
    (r"-----BEGIN (RSA |EC |)PRIVATE KEY-----", "private key"),
    (r"https://[^\s/@]+:[^\s/@]+@", "URL with embedded credentials"),
]
for path in walk((".mc", ".xml", ".md", ".jungle", ".py", ".yml", ".yaml", ".json"),
                 ("source", "tests", "resources", "scripts", ".github", ".vscode", ".")):
    if os.sep in path and not path.startswith((".github", ".vscode", "source", "tests", "resources", "scripts")):
        continue
    text = read(path)
    for pat, what in SECRET_PATTERNS:
        if re.search(pat, text):
            err(f"{path}: looks like a {what}")

# 4. Resource XML parses, FIT ids/sortOrders unique, every referenced string exists.
strings = {}
for path in walk((".xml",), ("resources",)):
    try:
        root = ET.parse(os.path.join(ROOT, path)).getroot()
    except ET.ParseError as e:
        err(f"{path}: XML parse error: {e}")
        continue
    for s in root.iter("string"):
        strings[s.get("id")] = s.text or ""
ids, orders = set(), set()
fit = ET.parse(os.path.join(ROOT, "resources", "fit", "fit_contributions.xml")).getroot()
for f in fit.iter("fitField"):
    fid, so = f.get("id"), f.get("sortOrder")
    if fid in ids:
        err(f"fit_contributions.xml: duplicate fitField id {fid}")
    if so in orders:
        err(f"fit_contributions.xml: duplicate sortOrder {so}")
    ids.add(fid)
    orders.add(so)
for path in walk((".xml",), ("resources",)):
    for ref in re.findall(r"@Strings\.(\w+)", read(path)):
        if ref not in strings:
            err(f"{path}: references missing string @Strings.{ref}")
props = {p.get("id") for p in ET.parse(os.path.join(ROOT, "resources", "settings", "properties.xml")).getroot().iter("property")}
settings = ET.parse(os.path.join(ROOT, "resources", "settings", "settings.xml")).getroot()
for s in settings.iter("setting"):
    key = s.get("propertyKey", "").replace("@Properties.", "")
    if key not in props:
        err(f"settings.xml: setting for unknown property {key}")
for key in props:
    if not re.search(r'"' + re.escape(key) + r'"', read("source/CourseRunField.mc")):
        err(f"properties.xml: property {key} is never read in CourseRunField.mc")

# 5. Firmware-dependent calls are guarded.
field = read("source/WorkoutTarget.mc")
if "getCurrentWorkoutStep" in field and "try {" not in field:
    err("WorkoutTarget.mc: getCurrentWorkoutStep must be wrapped in try/catch")
fitrec = read("source/FitRecorder.mc")
if "createField" in fitrec and "try {" not in fitrec:
    err("FitRecorder.mc: createField must be wrapped in try/catch")
crf = read("source/CourseRunField.mc")
for api in ("Attention.vibrate", "Attention.playTone"):
    name = api.split(".")[1]
    if api in crf and f"Attention has :{name}" not in crf:
        err(f"CourseRunField.mc: {api} must be guarded with 'Attention has :{name}'")

# 6. Source hygiene: no debug prints or TODOs left in shipped code, LF endings.
for path in walk((".mc",), ("source",)):
    text = read(path)
    if "System.println" in text:
        err(f"{path}: System.println left in shipped code")
    if re.search(r"\bTODO\b|\bFIXME\b", text):
        err(f"{path}: TODO/FIXME left in shipped code")
for path in walk((".mc", ".xml", ".md", ".jungle", ".py", ".yml"),
                 ("source", "tests", "resources", "scripts", ".github")):
    with open(os.path.join(ROOT, path), "rb") as f:
        if b"\r\n" in f.read():
            err(f"{path}: CRLF line endings (repo uses LF; see .gitattributes)")

# 7. Every model class has tests.
tests = read("tests/CourseRunTests.mc")
for cls in ("PaceBuffer", "CourseTracker", "WorkoutTarget", "Fmt"):
    if cls not in tests:
        err(f"tests/CourseRunTests.mc: no tests mention {cls}")

if errors:
    print("FAILED static checks:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("static checks passed")
