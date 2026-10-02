# WonderWhere

[Website](https://trystinduffy.github.io/wonder-where/) · [Privacy policy](https://trystinduffy.github.io/wonder-where/privacy/) · [Support](https://trystinduffy.github.io/wonder-where/support/)

App Store copy, privacy policy, support, and release notes: [AppStore/README.md](AppStore/README.md). The Xcode project and bundle identifier retain their original CompassDay names for compatibility.

Website editing and automatic GitHub Pages publishing: [website/README.md](website/README.md).

A native iPhone app for a day of secret destinations. Build a reusable plan, schedule a dated trip, then follow a compass that reveals each place when you arrive. Requires iOS 17 or later. No third-party packages or API keys are required.

## Plans and trips

**Home** is the library, with **Reusable plans**, **Scheduled trips**, **In progress**, and **Past trips**. Its gear button opens **Settings**, where you can change appearance and compass styles or set the configuration PIN.

Swipe left on a reusable plan and choose **Delete**, or use **Edit** on Home. Deleting the template keeps all scheduled, active, and past trips created from it. A saved trip can still be saved back as a reusable plan.

To rename a reusable plan, open it and choose **… → Rename plan**. Existing trips retain their own names.

A **Plan** stores places, area geometry, travel modes, duration ranges, optional-place priorities, hints, instructions, and time requirements. It contains no appointment dates or visit history. A **Trip** is an independent copy with a planned start, time zone, concrete times, actual progress, adjustments, and reminder settings.

1. Open **My adventure** on a fresh installation, or choose **New plan**.
2. Add and order places. Configure travel rows between them and the **Starting approach** mode.
3. Choose **Schedule trip**. Set the start and answer the generated time questions. Optional places can be excluded for this run.
4. Review the dated trip's estimates, adjustments, and notifications, then explicitly tap **Start trip**.

Viewing a trip does not start its clock. Only one trip can actively navigate at a time. Editing a trip does not edit its source plan or another run. **Save as reusable plan** creates a reusable copy; **Update original reusable plan** explicitly replaces its source plan. These actions omit dated bindings, progress, alarms, and automatic shortening/skipping. **Schedule another trip** creates a new run without deleting history.

## Maps after arrival

The compass is anchored to the full screen’s horizontal and vertical center, independently of the header and footer. On arrival, its circular surface expands into a close-up, tilted 3D Apple map with a pin at the place's **Explore** location. The same persistent surface animates in both directions: advancing to an unreached place returns to the compass, Back opens a previous visit’s map, and Resume returns to current navigation. These transitions work repeatedly, preserve the center, and respect Reduce Motion. Its revealed name, countdown, and instructions appear below. The map stays visible after leaving the area or losing GPS; a small arrow or location-search indicator overlays it when needed. History uses saved visit details without the active destination’s guidance or countdown. The navigation buttons stay in place. Tap the map to open that location in Apple Maps; it does not automatically start directions.

Back/history shows the visited place's saved map. The next unreached destination stays hidden. Live Explore edits update the active place's preview, while previous visits retain their historical geometry. Map tiles and 3D detail depend on Apple's coverage and available map data; navigation and visit progress remain independent of map loading.

## Apple Calendar

Open a dated trip and choose **… → Add to Apple Calendar**. Review the events, allow Calendar access, choose the account and calendar name, then tap **Create**. This creates a separate calendar containing the trip departure and all included stop events. The app remembers that calendar; return to the same screen and choose **Update** to apply later trip changes without creating another calendar. Events you add yourself are kept. The trip and calendar remain independent until you explicitly update.

Choose an **iCloud** account to share the calendar with other people. After creation, use **Open Apple Calendar**, then **Calendars → the info button beside the trip calendar → Add Person**. Apple Calendar manages invitations and sharing permissions. Its Public Calendar option also provides a shareable subscription link. See [Apple's calendar sharing instructions](https://support.apple.com/guide/iphone/share-icloud-calendars-iph7613c4fb/ios).

Full Calendar access is requested only when you connect. It is needed to create the separate calendar, find its existing events, and update them. Connection records are kept separately from trip data. Permission denial, unavailable accounts, and save failures remain visible; a deleted calendar requires an explicit **Recreate** action.

## Google Calendar

Open a dated trip and choose **… → Add to Google Calendar**. Allow Calendar access, choose an existing calendar in your Google account, review the events, and tap **Add**. Return to this screen and tap **Update** after changing the trip. Updates reuse the saved destination and trip-owned events; the calendar's name and other events stay intact. Apple and Google exports have independent connection records.

Your Google account must be connected in **iPhone Settings → Apps → Calendar → Calendar Accounts → Add Account → Google**, with **Calendars** enabled. On iOS 17, use **Settings → Calendar → Accounts**. Signing into the Google Calendar app alone does not connect it to the system calendar store. The picker lists writable calendars with their actual account names and requires an explicit choice; iOS does not expose a reliable Google-provider identifier. See [Google's iPhone calendar setup](https://support.google.com/calendar/answer/99358?co=GENIE.Platform%3DiOS&hl=en).

This adds events through the iPhone's calendar sync. A successful save confirms the local calendar write; Google server delivery depends on account sync and connectivity. Open Google Calendar to verify they have appeared. To have a separate calendar containing only the trip, first [create it in Google Calendar on the web](https://support.google.com/calendar/answer/37095?hl=en), then select it here once it has synced. Google does not support creating new Google calendars through Apple Calendar. Manage invitations and calendar access in Google's **Settings and sharing**; Compass Day does not send invitations or change sharing permissions.

## Sharing a trip calendar file

Open a dated trip and choose **… → Share calendar**, then choose Messages, Mail, AirDrop, or Save to Files in the standard iPhone share sheet. The `.ics` file contains a departure event and an event for each included place, with locations, map links, ordered instructions, and appointment/deadline details. Skipped and removed places are excluded. No calendar access permission is required.

Estimated events use the later end of the current arrival/departure ranges with the trip's current allocated durations. A place event spans arrival through departure, including any appointment waiting; its notes distinguish estimates from recorded times. Dates are exported as absolute UTC instants so calendar apps can display them in the recipient's time zone. Missing times or unanswered requirements must be resolved before sharing; export does not invent them or hide timing conflicts.

This shares a calendar snapshot, not a subscription. Export again after changing the trip. Compass Day's notification settings are not added to the recipient's calendar. Calendar files use [iCalendar (RFC 5545)](https://www.rfc-editor.org/rfc/rfc5545) and the native [Apple share controller](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller).

## Places and areas

Choose **Add place** to open the full place editor directly, with the name, areas, time settings, hints, and arrival instructions together. **Set location** opens one map popup; search results appear within that popup. Select a business or address, tap or move the center pin, enter coordinates, or use the current location. Saving the location returns to the same place editor with a visible area map. The new place is added only after its final **Save**; canceling does not add a partial place.

The place name is an editable alias in the full editor. Changing it leaves coordinates and radius intact. The location popup displays the center, radius circle, and a draggable edge marker. Search and uncached map tiles require a connection; entered coordinates do not.

Each place has three areas:

| Area | Behavior |
| --- | --- |
| **Entry** | Before arrival, the arrow points here. An eligible GPS observation records arrival once and reveals the place. |
| **Explore** | After arrival, being inside this area displays the arrival icon. Moving outside restores an arrow back here while keeping the name and instructions revealed. |
| **Exit** | **Next** requests departure and points here. Confirming Exit completes the visit and begins the next leg. |

New places start with **Use Entry for all areas** enabled. While this switch is on, Entry edits also update Explore and Exit, and their separate editing controls are hidden. Turn it off to configure each area independently—for example, an entrance, a larger area to explore, and a departure point. This choice is saved with the place.

Drag the radius marker to resize the circle, or use **+ / −** to double or halve its size. Radius is displayed automatically in feet or miles, with no keyboard entry or app-imposed maximum. Geometry is stored in meters with `Double` coordinates; large Explore areas can cover a city independently of a small Entry or Exit.

Optional **Navigation hint** text appears during navigation. **Arrival instructions** are an ordered list revealed at arrival; individual steps can be moved or deleted. Blank hints and instructions are omitted.

Edits to active geometry retarget guidance without clearing recorded arrival or elapsed time. Active-run reordering affects the remaining queue, preserving completed visits and the current destination. Removing a place preserves any recorded visit snapshot. Protected organizer controls can manually confirm an Entry or Exit when GPS cannot establish it.

The List/Map selector retains a native list and a muted, tilted Apple Maps overview. Straight neutral lines connect the places; numbered markers use the selected accent. The map is an overview rather than a route traced along roads.

## Time requirements and adaptation

**Time here** supports a fixed duration or a minimum–maximum range. New places default to five minutes. Zero is permitted; arrival and Next are still required. Optional places have a keep priority: lower numbers are considered for skipping first.

Plans declare the questions that scheduling must answer:

- **Appointment:** reach Entry by this time; the visit budget starts no earlier than this time.
- **Arrive by:** an Entry deadline, without mandatory waiting.
- **Leave by:** an Exit deadline.

The scheduling form supplies concrete dates and times in the selected trip time zone. Unanswered required times remain explicit; a missing value is not treated as an unconstrained, on-time schedule.

A visit's budget normally begins at arrival. For an early appointment, arrival is recorded immediately and waiting is separate. The budget anchor can change before it begins, then freezes. Next remains available before the appointment or minimum duration; an early departure is recorded honestly without a fictitious later visit start. Movement within the place through confirmed Exit is part of its budget.

The app derives countdowns from timestamps. Leaving Explore, reviewing a previous place, backgrounding, and relaunching do not restart a visit. The visit display indicates an exceeded allocation. **Running behind** means outstanding time requirements cannot be met under the remaining schedule. A recorded late arrival does not permanently mark every subsequent destination late.

Apple Maps supplies travel estimates for the selected walk, drive, or bike mode and anticipated departure. The displayed upper travel estimate adds 20%. The starting approach is included when an origin and estimate are available. Current remaining travel is distinct from a full-leg estimate; elapsed time alone is never subtracted as proof of movement.

The scheduler starts flexible visits at their configured maximum. If requirements are threatened, it:

1. Proportionally shortens useful, unspent flexible time, respecting minimums and actual elapsed time.
2. If needed, considers future optional places by keep priority.
3. Retains the active destination, including while approaching it, and places needed to change travel mode.
4. Verifies a usable replacement connection improves the schedule before committing a skip.

A skipped optional place's time requirement leaves the active schedule. Automatic changes do not re-expand durations or reinsert places. **Restore optional places and durations** explicitly restores the configured choices; subsequent recalculation can adjust them again if the constraints still require it.

**Start by** is the latest departure for the currently included route and allocated durations, using upper travel estimates and appointment waiting. It is checked against every outstanding constraint. An impossible gap between appointments remains impossible regardless of how early you start. The live completion range uses the same visit allocations at both ends, varying travel estimates and resulting waits. Durations format as minutes, hours, or days.

Before starting, conflicts are labeled **Schedule doesn’t fit** or **Schedule may run over**, with the largest overrun and each affected deadline beside its projected arrival or departure. **Running behind** is reserved for active trips. Where an earlier start resolves the current schedule, **Use latest feasible start** applies that departure explicitly. A **Leave by** requirement is the deadline for reaching that place’s Exit after the visit; moving this deadline earlier tightens the schedule. **Planned start** controls departure for the trip.

The trip summary separates remaining allocated visit time, remaining travel, free time before appointments, and visit time that can still be shortened. Each place shows its current allocation next to the configured fixed duration or allowed range, expected arrival, and planned departure. Time that can be shortened is already included in the visit allocation; free waiting before an appointment is separate. Missing estimates and unknown historical accounting stay explicitly unknown.

Each dated requirement shows the expected arrival or departure and the margin before or over its deadline. Setting a Leave by later than the existing planned departure has no effect. Tightening it can shorten flexible visits and advance later arrivals, but a later appointment can turn that gain into free waiting instead of an earlier completion time. Fixed visits and minimum durations are still respected.

Scheduled trips forecast from their planned start. Active trips prominently show their actual start and forecast from current progress; the original planned start becomes a read-only record. Use a newly scheduled trip to plan a later run instead of changing the original planned date of an active one.

Missing travel estimates do not hide conflicts that can already be proved from the appointments and visit durations. Those are labeled **At least … over**, while unknown travel, arrival, and completion estimates remain unavailable.

Travel rows allow manually entered ranges when Maps cannot provide an estimate. Missing effective connections after exclusions or skips can also receive a manual range. Manual connections apply to their saved endpoint geometry and mode, take precedence over Maps, and remain available offline. They are labeled as manual. Cached Maps estimates are distinguished from current estimates; missing travel data remains visibly unavailable rather than becoming a guessed time.

## Compass, history, and privacy

The arrow shows a straight-line bearing, not road or walking directions. Hold the phone in portrait orientation with its top pointing in the direction you are facing. Guidance uses geographic bearing and valid true heading; travel course is not substituted for the phone's orientation.

The distance display uses SF Symbols and miles rounded up in quarter-mile increments. Fire means within a quarter mile, sun means above a quarter mile through two miles, and snow means beyond two miles. Classification uses actual distance before rounding. GPS accuracy and the active area's radius are visible.

A small arrival radius does not block useful distant guidance: a fresh fix a mile away with ±1,000 feet uncertainty can still give a meaningful direction to a place with a 30-foot radius. Direction is withheld when the current position uncertainty includes the target center, combined bearing/heading uncertainty is too large, readings are stale, or true heading is unavailable. Arrival confirmation separately requires reported accuracy no worse than the Entry radius and an observed position inside it.

Compass, arrival, and search symbols transition in the same fixed space. First arrival gives three foreground haptic pulses. Names and instructions remain revealed if you overshoot, leave Explore, or lose accuracy. **Back** stays at the left and **Next** at the right. Next requests Exit; confirming the last Exit completes the trip.

**Back** reviews previously reached visits without changing active navigation, restarting timers, or rewinding progress. **Resume navigation** returns to the active destination. The house button opens **Home**, where you can select the active trip to edit its configuration. After completion, **Back to Home** returns to the library and saved trip history.

From Home, use the gear button to open **Settings → Configuration PIN** and set an optional four-digit PIN. Opening Home from the compass keeps this PIN guard during an adventure; without a PIN, a confirmation prevents an accidental reveal. Configuration and the organizer library remain protected. **Forgot PIN?** can remove the PIN after confirmation while preserving trips. This is a spoiler guard, not a security boundary.

**Settings → Appearance** contains preset/custom accent colors, hex entry, eight compass pointers, seven borders, and system light/dark appearance. Settings are stored locally and survive relaunch.

## Tracking, notifications, and offline operation

An active trip keeps location updates running while configuration is open and while the phone is locked or the app is backgrounded. Heading updates are reacquired when the compass returns to the foreground. Completion or cancellation stops active-trip tracking. Batched observations are processed chronologically; the app does not infer arrival merely because a straight line between sparse observations crosses a place.

Allow location access with Precise Location enabled. The app uses the Location updates background capability with a foreground-started When In Use session; it does not request Always authorization. See Apple's [background location configuration](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates).

Force-quitting, restarting the phone, or system termination can interrupt observations. Reopening resumes the saved trip, but it cannot reconstruct an unobserved arrival. Manual confirmation is available in configuration when needed.

Each dated trip has a **Notifications** screen organized by **Trip start**, **Arrivals**, **Place departures**, and **Appointments and deadlines**. **Before trip starts** alerts before the planned start, while place-departure alerts use planned Exit times. Deadline alerts identify the appointment, Entry deadline, or Exit deadline they refer to. **All** enables current events and arrival notices; **None** disables all saved events, including hidden or skipped ones. All settings default off; time-based alerts use a 15-minute lead when first enabled. On iOS 26 or later, choose **Alarm** or **Notification**. Earlier supported versions offer notifications. AlarmKit uses fixed-date, alert-only alarms; visit countdowns remain inside Compass Day. Permissions are requested when the corresponding delivery method is enabled. See Apple's [AlarmKit scheduling guidance](https://developer.apple.com/documentation/AlarmKit/scheduling-an-alarm-with-alarmkit).

Notification settings show actual scheduled delivery times or failures. Edits, skips, completion, cancellation, and reopening reconcile pending alerts without creating duplicates. A dismissed or finished alert is not silently re-armed by **All**. Newly calculated delivery times in the past do not unexpectedly fire. Delivered alerts omit place names.

**When you arrive** is an optional notice when arrival is recorded while the app is in the background. Background tracking records arrival without promising custom vibration pulses while locked. System-scheduled alerts can fire while the app is closed; schedule recalculation happens when the app runs or receives location events, not through a guaranteed continuously running background timer.

Saved plans, progress, area geometry, manual durations, and accepted route estimates are local. GPS and compass guidance can operate offline. Apple Maps search, new route estimates, and uncached map imagery require a connection. Full cached estimates may remain useful offline, but a stale or spatially unrelated approach estimate cannot establish current remaining travel.

## Storage and migration

The library is stored in the app's Application Support directory as `CompassDay/library.json`. A serial repository validates encoded data and performs atomic writes away from the UI thread. Durable changes are published after the save succeeds; write failures are surfaced. The storage protection permits writes while locked after the phone's first unlock following a reboot.

An existing `itinerary.json` migrates into a reusable plan and its current trip. Stop identities, order, recoverable visit history, active destination, hints, instructions, and deadlines are preserved. Existing circles become distinct Entry/Explore/Exit areas, existing visit durations become fixed ranges, and old deadlines become reusable requirements plus trip bindings. Unknown historical timestamps remain unknown. The original file and `itinerary.pre-library-migration.json` backup are kept. Appearance and PIN settings are not reset.

## Build, tests, and physical acceptance

Open `CompassDay.xcodeproj` directly in Xcode. Select the app target's development team if needed, connect and trust the iPhone, enable Developer Mode when requested, and run the CompassDay scheme. TestFlight is not required. Install updates over the existing app; uninstalling removes its local data.

Keep the saved signing configuration. The old `scripts/generate_project.py` generator overwrites project settings and does not represent the current source-file inventory; do not use it to regenerate this project. New Swift files need explicit entries in the Xcode project.

Run the unit tests on an installed simulator, substituting a destination available on the development machine:

```sh
xcodebuild -project CompassDay.xcodeproj -scheme CompassDay \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build -parallel-testing-enabled NO \
  -only-testing:CompassDayTests test CODE_SIGNING_ALLOWED=NO
```

Tests cover the production domain engine, stable command/phase identities, arrival/Exit/history transitions, stale and batched observations, geometry edits, migration and durable storage, appointment accounting, adaptive scheduling, manual and cached connections, and reminder reconciliation. Unit and replay tests establish deterministic behavior; they do not prove a physical compass or background delivery works on a particular device.

The simulator's **Simulator location** controls inject explicit latitude, longitude, heading, and accuracy into the same production location/transition path. They do not create a destination-relative alternate itinerary. Simulator data lives in its own app container, and automated fixtures use isolated test storage. Synthetic arrivals are real progress in that simulator trip; create another run to repeat it without altering history.

Before relying on the app for the day, perform physical acceptance outdoors: compare bearings with mapped targets and Apple Compass using the same true-north reference and phone orientation; rotate and hold still; pass a place and return; edit configuration and resume; lock the phone during an Entry and Exit; relaunch; and test with network access disabled. Validate alarm/notification permissions and delivery separately. A successful build, simulated replay, or installation does not establish that these device checks have passed.

Current implementation verification results, device migration evidence, and remaining physical acceptance checks are recorded in [VALIDATION.md](VALIDATION.md).
