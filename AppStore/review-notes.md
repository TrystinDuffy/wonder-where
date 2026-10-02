# App Review notes

WonderWhere is an iPhone app for outings whose destinations are revealed on arrival. No app account, sign-in, or review credentials are required. There is no default configuration PIN.

Review contact: Trystin Duffy, trystinduffy@gmail.com.

## Create and run a sample trip

1. On a fresh installation, open **My adventure** under **Reusable plans**, or use **New plan** to create a plan named **Review route**.
2. Tap **Add place**. In the place editor, tap **Set location**, search for a nearby public place, choose a result, and save the location. The same popup also allows choosing a point on the map or entering coordinates. Give the place an alias such as **First stop**. Keep **Use Entry for all areas** enabled and the default five-minute duration. Add an arrival instruction such as **Take a look around**, then tap **Save**.
3. Add a second public place. Tap **Schedule trip**, choose a planned start, then **Save**. No appointment questions appear unless time requirements were enabled in a place's editor. Unavailable route estimates do not prevent saving: in trip configuration, **Set approach estimate** and the travel rows allow manual travel durations.
4. Tap **Start trip** and allow location access while using the app. Precise Location improves arrival detection. A usable location and heading are needed to display a direction; otherwise the app displays a location-search indicator. The compass uses a straight geographic bearing, not road routing.
5. Physical arrival reveals the place's map, name, and instructions. **Next** requests departure through Exit, then advances to the next place. **Back** reviews reached places; **Resume navigation** returns to the current trip. The final Exit completes the trip.

## Review arrival without traveling

During an active trip, tap the **Home** house button and confirm **Open Home**. Open the trip's detail row under **In progress** and scroll below the place list to **Confirm arrival manually**. Tap it, then **Resume compass**. The arrival map and instructions are now revealed; the event is recorded as a manual confirmation.

After **Next**, if Exit has not been reached, use the same trip detail screen and **Confirm Exit manually**. This lets you review progression and completion without traveling. Both confirmations are marked manual. No simulator-only controls are required.

## Permissions and optional features

- Background location is limited to active trips. It records eligible arrivals and Exits while the screen is locked and stops on completion or cancellation. Foreground location is also used while choosing a starting location or planning a trip. Always authorization is not required. Force-quitting interrupts observation.
- Maps search, route estimates, and uncached map detail require connectivity; unavailable estimates can be entered manually. Tilted map detail depends on Apple's coverage. Tapping a revealed map opens Apple Maps without automatically starting directions.
- In a trip's **Notifications** screen, alerts are off by default. Enable only the alerts being reviewed. System notifications require permission. The optional **Alarm** delivery method uses AlarmKit on iOS 26 or later; earlier supported versions offer notifications.
- The trip's **…** menu contains **Add to Apple Calendar**, **Add to Google Calendar**, and **Share calendar**. Calendar access is requested only when connecting. Creation or updates require an explicit action. Google uses an existing calendar account connected in iPhone Settings; there is no in-app Google sign-in. The app does not send invitations or change calendar sharing permissions. Calendar-file sharing uses the standard share sheet and needs no calendar permission.
- **Home → Settings → Appearance** changes colors and compass styles. **Configuration PIN** is an optional safeguard against revealing destinations accidentally, not an account or a security boundary.

# Internal submission notes — do not paste into App Review

- The App Review contact telephone number is still required; it has not been supplied. Enter it in App Store Connect before submission.
- The GitHub Pages support and privacy policy URLs are set in metadata.json. Verify the public pages before App Store submission.
- Keep the existing icon. The customer-facing name is **WonderWhere**; the existing bundle identifier and saved-data identity remain unchanged.
- No reviewer should need to enable notifications, create calendar events, or connect an external account to test the core outing flow.
- Use a clean review installation with sample public places. Do not include the developer's personal itinerary, saved trip history, PIN, private coordinates, or calendar connection receipts in a submitted build or screenshot.
- These notes describe the current implementation. Complete physical location/background and system alert acceptance for the release build; simulator results alone do not establish device behavior.
