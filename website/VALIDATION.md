# Website validation — October 2, 2026

The dependency-free website builder produced the overview, privacy policy, support page, 404 page, stylesheet, and unchanged app icon. App Store metadata parses as JSON and contains all three production HTTPS URLs.

An isolated Chromium session checked all four documents at widths of 1280, 390, and 320 pixels, including 200% text sizing. No horizontal overflow or browser errors occurred. Internal page links, stylesheet, and icon loaded successfully. The privacy and support documents mark the current page, their contents controls expand and navigate to valid headings, and the keyboard skip link reaches the main content. External links and email links were not activated.

Desktop and mobile screenshots were visually reviewed. Local screenshots and the detailed browser report are in the ignored `build/website-review` folder.

The publication audit excluded every local `build*` directory and Xcode user state, checked source/documents for credentials and private device data, and generalized a validation paragraph containing the actual saved itinerary. Historical documentation screenshots contain demo content and are not included in the Pages artifact. The App Review paste section remains under 4,000 UTF-8 bytes.

This change adds the website and publishing workflow, updates the public copy and URL fields, and improves repository exclusions. It does not change app navigation, the stored trip library, signing settings, or the app icon. No physical-phone installation is part of website publication.
