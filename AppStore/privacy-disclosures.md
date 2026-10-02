# WonderWhere — private privacy submission notes

Reviewed against the app source on September 15, 2026. This file is working material for the developer; publish `privacy-policy.md`, not this file. Public contact: Trystin Duffy, trystinduffy@gmail.com. The public website URLs are recorded in `en-US/metadata.json`. The October 2 policy update adds GitHub Pages website hosting disclosure; it does not change the app's storage or data handling.

## App Store privacy label

**Source-based recommendation: “No, we do not collect data from this app,” provided the release and developer operations match this audit.** Do not equate that label with “no data ever leaves the device.”

Apple distinguishes on-device use from developer/partner collection and says developers need not disclose information Apple collects through its own frameworks. Developer use of data received from those services must be evaluated separately. [Apple's App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

Before submitting that answer, confirm whether the developer receives or retains app analytics or diagnostics from Apple, adds a support form, or otherwise receives app data beyond voluntary correspondence. The source alone cannot establish those operational practices. A future SDK, server, cloud sync, or telemetry feature requires a new assessment.

| Data or activity | Observed behavior | Label assessment for this implementation |
| --- | --- | --- |
| Precise location, heading, accuracy | Core Location drives guidance and visit detection. Starting coordinates, route-estimate coordinates, and visit/place records are saved locally. MapKit receives route coordinates when estimates are requested. | No developer location collection endpoint found. Explain local use and Apple's processing in the policy; do not describe the app as keeping all location exclusively on-device. |
| Plans, dates, hints, instructions, history | Saved as an on-device library; no account or remote library service. | Local content does not itself establish collection. User-directed exports are separately disclosed in the policy. |
| Search terms and maps | MapKit place search, autocomplete, map rendering, and ETA requests. | Apple framework/service processing; no separate developer search log or analytics found. |
| Calendar information | EventKit reads calendar/account lists and events needed to match exports; saves requested changes. Google calendars use the existing iOS calendar account. | No calendar-library upload to the developer. Do not claim write-only permission or that the app never reads calendar events. |
| Calendar/file exports | iOS share sheet or selected calendar account receives trip details, including coordinates, hints, instructions, and dates. | User-directed sharing to chosen services, not a developer-hosted sharing feature. Reassess if a direct third-party integration is added. |
| Configuration PIN and settings | PIN, appearance, screen state, and notification receipts use local preferences. | No developer collection found. PIN is stored as a string, not encrypted credentials in a keychain. |
| Advertising identifiers and tracking | No advertising or analytics SDK, IDFA access, tracking domain, or fingerprinting code found. | No tracking; no ATT prompt is indicated by this implementation. |
| Support email | Public Gmail address; no in-app upload or support-submission service in the audited source. | Confirm actual support handling. If a future in-app support flow collects data, evaluate contact information, user content, and diagnostics against Apple's optional-disclosure criteria; do not assume support is automatically exempt. |
| Apple diagnostics and app analytics | No custom crash or analytics integration found. Apple-side account settings and developer receipt/use are outside this code audit. | Confirm operational collection before submitting. If developer/partner receipt and retention constitutes collection, declare the applicable data types and purposes. |

Apple's definition concerns transmission and retention beyond servicing a request; its optional-disclosure exception has multiple conditions, including infrequent optional collection and clear, affirmative submission. Use the complete current guidance for a changed support flow. [Apple's collection and optional-disclosure rules](https://developer.apple.com/app-store/app-privacy-details/).

## Privacy manifest

The production target needs its own bundled `PrivacyInfo.xcprivacy`; an empty data-collection list does not replace required-reason API declarations. This document records the declarations; verify their inclusion in the final archive separately.

| Manifest entry | Recommended value | Verified reason |
| --- | --- | --- |
| `NSPrivacyTracking` | `false` | No tracking behavior or SDK found. |
| `NSPrivacyTrackingDomains` | Empty array or omitted | No tracking domains. Apple Maps and calendar domains must not be invented as tracking domains. |
| `NSPrivacyCollectedDataTypes` | Empty array under the source-based assessment above | Reconcile with the final App Store Connect answers and operational practices. |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Reads/writes this app's own preferences: appearance, PIN, navigation presentation, and arrival-notification receipts. |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Reads creation dates of temporary calendar-export directories inside the app's container to remove old exports. |

Apple's approved reasons cover app-private defaults and metadata for files within the app's own container. These are purpose declarations, not declarations of data collection. [Approved reason codes](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), [Required-reason manifest guidance](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

No production use of disk-capacity APIs, boot-time APIs, or active-keyboard inspection was found. Verify the final archive and Xcode privacy report, including linked dependencies, before upload. The project currently shows no external package or CocoaPods dependencies; system frameworks do not need to be represented as third-party SDKs.

## Verified source evidence

Line references identify the audited implementation and may move during branding edits.

- [TripRepository.swift](/Users/duffy/MK/CompassDay/TripRepository.swift:40): library lives in Application Support; atomic storage uses file protection available after first unlock. The retained legacy migration backup is also local.
- [TripDomain.swift](/Users/duffy/MK/CompassDay/TripDomain.swift:61): place names, coordinates, areas, instructions, address, timing requirements; [trip and visit records](/Users/duffy/MK/CompassDay/TripDomain.swift:216) retain snapshots, milestone timestamps, origin, and estimates. There is no continuous persisted location trail.
- [LocationService.swift](/Users/duffy/MK/CompassDay/LocationService.swift:78): location permission, precise accuracy, active background updates, and heading. [TripStore.swift](/Users/duffy/MK/CompassDay/TripStore.swift:282): starts/stops tracking according to active trip state.
- [StopEditor.swift](/Users/duffy/MK/CompassDay/StopEditor.swift:234): MapKit autocomplete and resolution send search input to Apple's services. [TripRoutes.swift](/Users/duffy/MK/CompassDay/TripRoutes.swift:100): route start/end, mode, and departure-time requests. [CompassView.swift](/Users/duffy/MK/CompassDay/CompassView.swift:419): opens the selected place in Apple Maps.
- [TripAppleCalendarService.swift](/Users/duffy/MK/CompassDay/TripAppleCalendarService.swift:359): requests full access, reads accounts/calendars, queries events for export reconciliation, and saves user-requested events. [Connection records](/Users/duffy/MK/CompassDay/TripAppleCalendarService.swift:296) persist calendar/account/event identifiers and an app-generated ownership token locally. The token is an export marker, not an advertising identifier.
- [TripCalendarExport.swift](/Users/duffy/MK/CompassDay/TripCalendarExport.swift:134): exported notes include schedule information, coordinates, hints, instructions, and deadlines. [TripCalendarSharing.swift](/Users/duffy/MK/CompassDay/TripCalendarSharing.swift:8): temporary files and iOS sharing; creation-date cleanup occurs on a later export, so do not promise automatic deletion exactly seven days later.
- [TripReminders.swift](/Users/duffy/MK/CompassDay/TripReminders.swift:415): local notifications and fixed-date system alarms. [Arrival notices](/Users/duffy/MK/CompassDay/TripReminders.swift:452) have generic text and local delivery receipts. No remote-push service or device-token registration found.
- [CompassDayApp.swift](/Users/duffy/MK/CompassDay/CompassDayApp.swift:239): PIN stored in `UserDefaults`; reset available from the unlock screen. It prevents accidental spoilers, not access to the underlying data.
- [TripLibraryView.swift](/Users/duffy/MK/CompassDay/TripLibraryView.swift:40) and [TripStore.swift](/Users/duffy/MK/CompassDay/TripStore.swift:144): reusable-plan deletion keeps existing trips. No trip deletion or erase-all UI/command exists in this version. Cancellation changes lifecycle, not retention.
- [Info.plist](/Users/duffy/MK/CompassDay/Info.plist:4) and [project settings](/Users/duffy/MK/CompassDay.xcodeproj/project.pbxproj:389): location background mode, AlarmKit/calendar permission text, and generated When In Use location explanation. No contacts, camera, microphone, photo-library, health, or advertising permission usage found.

## Publication and ongoing accuracy

Publish the policy at a stable, publicly accessible URL and use that exact URL in App Store Connect and the app's accessible privacy link. A contact email is not the privacy-policy URL. Apple requires a policy URL and permits an optional Privacy Choices URL. [App Store Connect privacy setup](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

Keep the public policy's September 15, 2026 last-updated date only if no substantive changes follow. It is a reviewed draft until publication. Confirm that the support correspondence practice described in the policy matches actual handling; no fixed retention period is invented.

Do not promise complete offline operation, end-to-end encryption, encrypted PIN storage, automatic calendar deletion when the app is deleted, a user-account deletion button, or a full in-app trip-history deletion control. The source does not support those claims. Device backups and calendar/shared copies remain subject to their own controls. Apple's [storage guidance](https://support.apple.com/en-us/108429) confirms that offloading keeps app documents and data, while deleting the app removes its local data. [Apple Maps & Privacy](https://www.apple.com/legal/privacy/data/en/apple-maps/) explains Apple's separate map processing.
