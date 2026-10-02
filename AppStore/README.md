# WonderWhere — App Store release copy

Prepared September 15, 2026 for Trystin Duffy. Public contact: **trystinduffy@gmail.com**. Customer-facing app name: **WonderWhere**. Keep the existing app icon.

Start with [the readable store listing](store-listing.md) to review the finished customer-facing copy.

## Ready-to-use copy

| Item | File | Where it belongs |
| --- | --- | --- |
| App Store name, subtitle, promotional text, keywords, release text, categories, copyright, and contact fields | [en-US/metadata.json](en-US/metadata.json) | Corresponding App Store Connect fields; do not paste the internal notes into public fields |
| Full description | [en-US/description.txt](en-US/description.txt) | App Store description |
| Privacy policy | [privacy-policy.md](privacy-policy.md) | A public HTTPS page; also bundled in the app's Settings |
| Help and support | [support.md](support.md) | A public HTTPS support page; also bundled in the app's Settings |
| Story and attribution | [about.md](about.md) | The app's About page; optional website introduction |
| App Review instructions | [review-notes.md](review-notes.md) | Paste only the App Review section into review notes |
| Screenshot headlines and captions | [screenshot-copy.md](screenshot-copy.md) | Captions around screenshots of the actual release interface |
| Privacy label and API declaration rationale | [privacy-disclosures.md](privacy-disclosures.md) | Private submission reference; not public copy |
| Permission prompts | [permission-copy.md](permission-copy.md) | Reference for the purpose strings already applied to the project |

The public policy, About page, and support page use the supplied name and email. They do not contain placeholder contact details. Their Markdown files are the same files packaged with the app, so corrections need only be made in one place.

## Identity and release configuration

- Display name: **WonderWhere**.
- Version: **1.0**. Build: **1**. Increment the build number for each subsequent uploaded build.
- Existing bundle identifier: **com.duffy.CompassDay**. Keep it and the current signing team to preserve the app's identity.
- Existing storage paths, preference keys, notification identities, and calendar event ownership markers are retained. Historical internal names are not customer-facing branding to rename indiscriminately.
- Current icon: `CompassDay/Assets.xcassets/AppIcon.appiconset/AppIcon.png`. Its contents have not changed.
- iPhone, iOS 17 or later. Alarms require iOS 26 or later. Maps imagery and estimates have network and coverage limits.
- The release contains no developer itinerary or phone backup. A new installation starts with an empty reusable plan.

## Public website URLs

The GitHub Pages website uses the same policy and support source files that are bundled with the app. Its URLs are entered in `en-US/metadata.json` for copying into App Store Connect:

- **Privacy Policy URL:** https://trystinduffy.github.io/wonder-where/privacy/
- **Support URL:** https://trystinduffy.github.io/wonder-where/support/
- **Marketing URL:** https://trystinduffy.github.io/wonder-where/

See [website publishing instructions](../website/README.md) for updates. The site includes only public copy and the current app icon; it does not publish this submission guide or private device artifacts as website pages.

## Fields that still require real account or publishing information

1. **Review contact telephone number:** enter Trystin Duffy's preferred review contact number in App Store Connect. It has not been supplied and is not invented in the copy.
2. **Developer membership and agreements:** renew the membership and complete the account's current required agreements.
3. **App name availability:** reserve WonderWhere when creating the App Store Connect record. Local branding does not reserve an App Store name.
4. **Price and availability:** the previous recommendation was a free public release. No price or country selection has been applied; the description does not promise a price. Select the actual release settings in App Store Connect.
5. **Screenshots:** the captions are prepared; the finished store screenshots still need to be captured and uploaded using sample data and the ordinary release interface.

These are remaining submission fields and assets, not requests to change the approved name or icon. App Store metadata has not been submitted to Apple.

## Privacy, age rating, and other declarations

The source audit supports a Data Not Collected recommendation for the app as implemented, with the operational checks explained in `privacy-disclosures.md`. This is distinct from permissions and user-directed sharing: Apple Maps requests and optional calendar/file exports can send information off-device. Do not replace the policy with an absolute "nothing leaves your phone" claim.

The bundled privacy manifest declares app-private UserDefaults access (`CA92.1`) and creation-date inspection of the app's own temporary export files (`C617.1`). There are no tracking domains or custom collection SDKs in this version. Recheck any added dependencies before upload. [Apple's required-reason guidance](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).

Complete Apple's current age-rating questionnaire from the actual features. This version has location services, private user-written plans, optional system notifications, and calendar-file sharing. It has no public content feed, messaging service, advertising, gambling, medical advice, or unrestricted in-app browser. Its spoiler PIN is not a parental-control system. Apple assigns the final rating; the copy does not claim one.

For the license agreement, use Apple's standard EULA. A Terms of Use link is included in Settings. No custom license text or subscription terms are needed for the current feature set. [Apple's standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).

The audited app uses no custom or third-party encryption implementation. `ITSAppUsesNonExemptEncryption` is set to `false` for its use of Apple's operating-system services. Reassess if dependencies or cryptographic features change. [Apple's export-compliance guidance](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/).

Do not claim App Store Accessibility Nutrition Labels solely from the presence of accessibility identifiers or native controls. Verify the complete release flows for each support claim before selecting it. Also choose Mac/Apple Vision compatibility deliberately; hardware-compass behavior needs a compatible iPhone.

## Final preparation

Archive and validate a signed Release build, inspect its bundled privacy manifest and version fields, and verify the new pages. Test a clean installation and an update retaining the existing library, permission-denied behavior, physical compass/background arrivals, alert delivery, and real calendar-account sync. Use the supplied review notes to make manual arrival and Exit confirmation discoverable to App Review. The screenshot files, membership status, and Apple review remain separate from the public website.

Apple's current field limits and required submission information are documented in [platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) and [app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/).
