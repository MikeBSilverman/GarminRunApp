# Connect IQ store listing

## Name
CourseRun

## Tagline (short description)
Race the course, not the GPS. Distance and pace along your route, plus an on-pace band from your workout or goal.

## Description

Your watch says 13.35 miles at the finish of a half marathon. The course was 13.11. Every race, GPS reads long, so the pace on your wrist is slower than the pace you're actually running.

CourseRun is a full-screen data field that fixes that. Load the race course, and the big number is your distance **along the course**, not the GPS line. Your average pace, your last mile, and your projected finish are all built on it. Mile splits flash where the mile markers really are.

**On-pace band.** The top of the screen turns green, red or blue: ON PACE, SLOW DOWN, or SPEED UP. It follows the pace target of the workout you're running (Garmin Coach, daily suggested workouts, calendar workouts), including heart-rate targets. Racing without a workout? Set a goal pace and the band shows how many seconds you're ahead of or behind it at this point in the course, and buzzes when you drift.

**Everything on one screen**
- Course distance (or distance to go)
- Projected finish time
- Course average pace
- Last mile, last km, or lap pace
- Timer and heart rate
- Step name and target range during workouts

**Before you press Start** it tells you whether a course is loaded: COURSE READY, NO COURSE, or CHECK LENGTH if the loaded course doesn't match the race distance you set.

**Works with what you already do.** It's a data field inside the native Run activity, so Garmin Coach, course navigation, Garmin Connect and Strava sync all work as before. Course distance and course pace are also saved into the activity, so Garmin Connect shows them on the activity page.

**No course loaded?** It still works as a clean running screen using GPS distance.

**Setup**
1. Run > hold UP > Run Settings > Data Screens > Add New > Custom Data > 1 field > Connect IQ Fields > CourseRun.
2. Before a race: hold UP > Navigation > Courses > the race > Do Course. Add your workout as usual.
3. Optional settings in the Connect IQ app: goal pace, race distance (e.g. 13.11), alerts, right-hand pace, distance to go.

Units follow your watch. Light and dark backgrounds supported. No network access; it only reads your heart-rate zones and writes two extra fields into your own activity. Open source (MIT): https://github.com/MikeBSilverman/GarminRunApp

## What's new (0.2.0)
First public release.

## Category
Data Fields > Running

## Permissions explanation (for the review form)
UserProfile: heart-rate zones, to turn zone-based workout targets into beats per minute.
FitContributor: records course distance and course pace into the activity so Garmin Connect can display them.

## Support
GitHub issues: https://github.com/MikeBSilverman/GarminRunApp/issues

## Assets
- Hero banner 1440x720: art/CourseRun_Hero_Banner_1440x720.png
- Store icon 128x128: art/CourseRun_StoreIcon_128.png
- Launcher icon 512: art/courserun_icon_512.png
