import XCTest

/// Exercises the shared production trip engine through native controls with independent geographic
/// simulator input. Each test has an isolated library, appearance, access, and reminder namespace.
final class TripFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testScheduledTripSharesCalendarFileThroughNativeShareSheet() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Lunch together", app: app)

        // Configure a real manual approach through its native editor. This makes the scheduled
        // trip's dates complete without depending on live GPS or a Maps request in the simulator.
        tapVisible(app.buttons["Set approach estimate"], app: app)
        XCTAssertTrue(app.navigationBars["Travel"].waitForExistence(timeout: 5))
        setSwitch(app.switches["Enter travel time manually"], enabled: true, app: app)
        XCTAssertTrue(app.textFields["visit-duration"].exists)
        app.navigationBars["Travel"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        app.buttons["plan-options"].tap()
        let share = app.buttons["share-trip-calendar"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()

        // This is the system's file share sheet, not an app confirmation that export succeeded.
        // Inspect its attachment and system action without sending a message or saving a file.
        let saveToFiles = app.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10),
                      "Calendar export must present the native file share sheet")
        XCTAssertFalse(app.alerts["Calendar unavailable"].exists)
        let filename = app.otherElements["LP.CaptionBar.TopCaption"]
        let fileType = app.otherElements["LP.CaptionBar.BottomCaption"]
        expectLabel(filename, contains: "My adventure")
        expectLabel(fileType, contains: "ICS File")
        attachScreenshot("Scheduled trip calendar share sheet", app: app)
        app.buttons["header.closeButton"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
    }

    func testScheduledTripCreatesAppleCalendarAndUpdatesSameCalendarAfterRelaunch() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Calendar lunch", app: app)

        // Give the scheduled trip complete dates without relying on GPS or network routing.
        tapVisible(app.buttons["Set approach estimate"], app: app)
        XCTAssertTrue(app.navigationBars["Travel"].waitForExistence(timeout: 5))
        setSwitch(app.switches["Enter travel time manually"], enabled: true, app: app)
        app.navigationBars["Travel"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        // This flow creates a real EventKit calendar in the test simulator's calendar store.
        // The isolated trip library and unique name keep it separate from other test runs.
        let calendarName = "CompassDay UI " + String(UUID().uuidString.prefix(8))
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Calendar full access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow Full Access")).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        app.buttons["plan-options"].tap()
        let addCalendar = app.buttons["add-apple-calendar"]
        XCTAssertTrue(addCalendar.waitForExistence(timeout: 5))
        addCalendar.tap()
        XCTAssertTrue(app.navigationBars["Apple Calendar"].waitForExistence(timeout: 5))
        let access = app.buttons["apple-calendar-access"]
        if access.waitForExistence(timeout: 3) {
            access.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow Full Access")).firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }

        let name = app.textFields["apple-calendar-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "Full calendar access must reveal calendar configuration")
        replace(name, with: calendarName, app: app)
        let save = app.buttons["apple-calendar-save"]
        expectLabel(save, contains: "Create calendar")
        XCTAssertTrue(save.isEnabled, "A writable simulator calendar account must be selected by default")
        save.tap()
        let success = app.staticTexts["apple-calendar-success"].firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 10), "Real EventKit creation must succeed before reporting success")
        attachScreenshot("Created Apple Calendar", app: app)
        app.buttons["apple-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        // Reopening the isolated library must retain the EventKit connection, so the next
        // action updates the same calendar rather than silently creating another one.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 8))
        let scheduled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-trip-")).firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
        tapVisible(scheduled, app: app)
        app.buttons["plan-options"].tap()
        XCTAssertTrue(addCalendar.waitForExistence(timeout: 5))
        addCalendar.tap()
        XCTAssertTrue(app.navigationBars["Apple Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, calendarName)
        expectLabel(save, contains: "Update calendar")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(success.waitForExistence(timeout: 10))
        attachScreenshot("Updated connected Apple Calendar", app: app)
        app.buttons["apple-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
    }

    func testGoogleCalendarOptionAddsToChosenCalendarAndUpdatesSameTargetAfterRelaunch() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Google calendar lunch", app: app)
        tapVisible(app.buttons["Set approach estimate"], app: app)
        XCTAssertTrue(app.navigationBars["Travel"].waitForExistence(timeout: 5))
        setSwitch(app.switches["Enter travel time manually"], enabled: true, app: app)
        app.navigationBars["Travel"].buttons["Save"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        // Create a unique local target through the production Apple Calendar flow. The Google
        // option uses EventKit's existing-calendar path; this verifies native writes and saved
        // selection without introducing a Google account, network dependency, or test hook.
        let calendarName = "CompassDay Google UI " + String(UUID().uuidString.prefix(8))
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Calendar full access") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow Full Access")).firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }

        app.buttons["plan-options"].tap()
        let appleOption = app.buttons["add-apple-calendar"]
        XCTAssertTrue(appleOption.waitForExistence(timeout: 5))
        appleOption.tap()
        XCTAssertTrue(app.navigationBars["Apple Calendar"].waitForExistence(timeout: 5))
        let access = app.buttons["apple-calendar-access"]
        if access.waitForExistence(timeout: 3) {
            access.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Allow Full Access")).firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        let appleName = app.textFields["apple-calendar-name"]
        XCTAssertTrue(appleName.waitForExistence(timeout: 10))
        replace(appleName, with: calendarName, app: app)
        let appleSave = app.buttons["apple-calendar-save"]
        expectLabel(appleSave, contains: "Create calendar")
        XCTAssertTrue(appleSave.isEnabled)
        appleSave.tap()
        XCTAssertTrue(app.staticTexts["apple-calendar-success"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["apple-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        app.buttons["plan-options"].tap()
        let googleOption = app.buttons["add-google-calendar"]
        XCTAssertTrue(googleOption.waitForExistence(timeout: 5))
        googleOption.tap()
        XCTAssertTrue(app.navigationBars["Google Calendar"].waitForExistence(timeout: 5))
        let picker = app.buttons["google-calendar-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let googleSave = app.buttons["google-calendar-save"]
        expectLabel(googleSave, contains: "Add events")
        XCTAssertFalse(googleSave.isEnabled, "A Google Calendar destination must be chosen explicitly")
        XCTAssertFalse(app.staticTexts["google-calendar-connected-name"].exists)
        tapVisible(picker, app: app)
        tapVisible(app.staticTexts[calendarName].firstMatch, app: app)
        XCTAssertTrue(app.navigationBars["Google Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(googleSave.isEnabled)
        googleSave.tap()
        let success = app.staticTexts["google-calendar-success"].firstMatch
        expectLabel(success, contains: "Added 2 events in \(calendarName).")
        expectLabel(app.staticTexts["google-calendar-connected-name"].firstMatch, contains: calendarName)
        attachScreenshot("Added events to explicitly chosen calendar", app: app)
        app.buttons["google-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 8))
        let scheduled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-trip-")).firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
        tapVisible(scheduled, app: app)
        app.buttons["plan-options"].tap()
        XCTAssertTrue(googleOption.waitForExistence(timeout: 5))
        googleOption.tap()
        XCTAssertTrue(app.navigationBars["Google Calendar"].waitForExistence(timeout: 5))
        expectLabel(app.staticTexts["google-calendar-connected-name"].firstMatch, contains: calendarName)
        expectLabel(googleSave, contains: "Update events")
        XCTAssertTrue(googleSave.isEnabled)
        googleSave.tap()
        expectLabel(success, contains: "Updated 2 events in \(calendarName).")
        attachScreenshot("Updated saved Google Calendar destination", app: app)
        app.buttons["google-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        // The provider options keep separate connection receipts even when this test selects
        // the same local calendar. Adding/updating must not replace the Apple connection.
        app.buttons["plan-options"].tap()
        XCTAssertTrue(appleOption.waitForExistence(timeout: 5))
        appleOption.tap()
        XCTAssertTrue(app.navigationBars["Apple Calendar"].waitForExistence(timeout: 5))
        XCTAssertTrue(appleName.waitForExistence(timeout: 10))
        XCTAssertEqual(appleName.value as? String, calendarName)
        expectLabel(appleSave, contains: "Update calendar")
        app.buttons["apple-calendar-done"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
    }

    func testDeletingReusablePlanKeepsScheduledTrip() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Saved destination", app: app)
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")

        // Scheduling pushes the new run above its source plan. Both are ordinary navigation
        // destinations, so use each native Back control to return to the library.
        app.navigationBars.buttons.firstMatch.tap()
        expectLabel(app.buttons["open-compass"], contains: "Schedule trip")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 5))

        let plans = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reusable-plan-"))
        let scheduled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-trip-"))
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(scheduled.count, 1)
        let planID = plans.firstMatch.identifier
        let tripID = scheduled.firstMatch.identifier
        let plan = app.buttons[planID]
        reveal(plan, app: app)
        plan.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: plan)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(plans.count, 0)
        XCTAssertTrue(app.buttons[tripID].exists, "Deleting a template must preserve its scheduled run")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 8))
        XCTAssertEqual(plans.count, 0, "The deleted plan must not be recreated on relaunch")
        XCTAssertTrue(app.buttons[tripID].exists)
        tapVisible(app.buttons[tripID], app: app)
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
        XCTAssertTrue(app.staticTexts["Saved destination"].exists,
                      "The surviving trip keeps its independent copy of the places")
    }

    func testHomeSettingsOpensAppearance() {
        let app = launchFresh()
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        tapVisible(app.buttons["Appearance"], app: app)
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["appearance-options"].exists)
        app.buttons["appearance-done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testWonderWhereSettingsLoadsBundledPrivacyAboutAndHelp() {
        let app = launchFresh()
        XCTAssertTrue(app.navigationBars["WonderWhere"].waitForExistence(timeout: 5))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        tapVisible(app.buttons["privacy-policy"], app: app)
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["app-information-document"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["WonderWhere Privacy Policy"].exists,
                      "The privacy page must load its bundled document, not fallback text")
        let privacyContact = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "For privacy questions or support, contact")).firstMatch
        expectLabel(privacyContact, contains: "trystinduffy@gmail.com")
        attachScreenshot("WonderWhere bundled Privacy Policy", app: app)
        app.navigationBars["Privacy Policy"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        tapVisible(app.buttons["about-wonderwhere"], app: app)
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["About WonderWhere"].exists)
        XCTAssertTrue(app.staticTexts["Made by Trystin Duffy."].exists)
        app.navigationBars["About"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        tapVisible(app.buttons["app-help"], app: app)
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["WonderWhere Help"].exists)
        XCTAssertTrue(app.staticTexts["Contact"].exists)
        let helpContact = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "For help, feedback, or privacy questions")).firstMatch
        expectLabel(helpContact, contains: "trystinduffy@gmail.com")
        // Inspect the contact text without activating its mail link.
    }

    func testNewPlaceMapAndIndependentExploreRadiusPersistWithAlias() {
        let app = launchFresh()
        openTemplate(app)
        beginAddingPlace("Park", app: app)
        let preview = app.descendants(matching: .any)["place-area-map"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "A newly selected location must open full details with its area map")
        attachScreenshot("New place full details", app: app)
        reveal(app.switches["shared-entry-area"], app: app)
        XCTAssertEqual(app.switches["shared-entry-area"].value as? String, "1")
        XCTAssertFalse(app.buttons["edit-explore-area"].exists)
        setSwitch(app.switches["shared-entry-area"], enabled: false, app: app)
        tapVisible(app.buttons["edit-explore-area"], app: app)
        XCTAssertTrue(app.descendants(matching: .any)["location-map"].firstMatch.waitForExistence(timeout: 5))
        let radius = app.staticTexts["area-radius"]
        expectLabel(radius, contains: "100 ft")
        XCTAssertFalse(app.textFields["area-radius"].exists, "The map controls adjust radius without a manual number field")
        let increase = app.buttons["increase-radius"]
        for _ in 0..<11 { increase.tap() }
        expectLabel(radius, contains: "38.79 mi")
        attachScreenshot("Explore city radius", app: app)
        app.buttons["save-location"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        replace(app.textFields["place-name"], with: "Our park", app: app)
        XCTAssertFalse(app.descendants(matching: .any)["place-search"].firstMatch.exists,
                       "Changing a place alias must not reopen location search")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["place-row-1"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openTemplate(app)
        tapVisible(app.buttons["place-row-1"], app: app)
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Our park")
        reveal(app.switches["shared-entry-area"], app: app)
        XCTAssertEqual(app.switches["shared-entry-area"].value as? String, "0")

        tapVisible(app.buttons["edit-explore-area"], app: app)
        expectLabel(radius, contains: "38.79 mi")
        expectCoordinateFields(latitude: 35.4676, longitude: -97.5164, app: app)
        app.buttons["save-location"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))

        tapVisible(app.buttons["edit-entry-area"], app: app)
        expectLabel(radius, contains: "100 ft")
        expectCoordinateFields(latitude: 35.4676, longitude: -97.5164, app: app)
        let search = app.descendants(matching: .any)["place-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("coffee")
        XCTAssertEqual(search.value as? String, "coffee")
        app.buttons["cancel-place-search"].tap()
        expectCoordinateFields(latitude: 35.4676, longitude: -97.5164, app: app)
        app.buttons["save-location"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        reveal(app.textFields["place-name"], app: app)
        XCTAssertEqual(app.textFields["place-name"].value as? String, "Our park")
    }

    func testSearchAcceptsFirstTapAndPlaceDurationAndInstructionsPersist() {
        let app = launchFresh()
        openTemplate(app)
        tapVisible(app.buttons["add-place"], app: app)
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-place"].isEnabled)
        tapVisible(app.buttons["place-area-map"], app: app)
        let search = app.descendants(matching: .any)["place-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("jam")
        XCTAssertEqual(search.value as? String, "jam", "The first tap must focus the native search input")
        app.buttons["cancel-place-search"].tap()
        app.navigationBars["Location"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-place"].isEnabled)
        app.navigationBars["Add place"].buttons["Cancel"].tap()
        addPlace("Lunch", app: app)

        tapVisible(app.buttons["place-row-1"], app: app)
        let duration = app.textFields["visit-duration"]
        replace(duration, with: "17", app: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(duration.value as? String, "17")
        tapVisible(app.buttons["add-instruction"], app: app)
        let instruction = app.textFields["Instruction"].firstMatch
        tapVisible(instruction, app: app)
        instruction.typeText("Take a photo together")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["place-row-1"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openTemplate(app)
        tapVisible(app.buttons["place-row-1"], app: app)
        reveal(duration, app: app)
        XCTAssertEqual(duration.value as? String, "17")
        let savedInstruction = app.textFields.matching(NSPredicate(format: "value == %@", "Take a photo together")).firstMatch
        reveal(savedInstruction, app: app)
        XCTAssertTrue(savedInstruction.exists)
    }

    func testSchedulingAsksForRequiredTimeAndKeepsTemplateReusable() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Dinner", app: app)
        tapVisible(app.buttons["place-row-1"], app: app)
        let appointment = app.switches["Appointment"]
        reveal(appointment, app: app)
        // SwiftUI exposes the whole labeled row as a switch and the native UISwitch beneath it.
        // Bring the row above the sheet's bottom edge, then target the actual native control.
        setSwitch(appointment, enabled: true, app: app)
        setSwitch(app.switches["Leave by"], enabled: true, app: app)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        let save = app.buttons["save-scheduled-trip"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Declared requirements must be answered rather than silently assigned a date")
        let timeQuestions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "schedule-requirement-"))
        XCTAssertEqual(timeQuestions.count, 2)
        for index in 0..<2 {
            tapVisible(timeQuestions.element(boundBy: index), app: app)
            XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5))
            app.buttons["Set time"].tap()
        }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
        XCTAssertFalse(app.staticTexts["trip-complete"].exists)
        XCTAssertFalse(app.staticTexts["Running behind"].exists, "A scheduled trip has not started running")
        // Native LabeledContent can expose its label and value as separate text elements.
        // Read both so the test verifies the actual breakdown, not just the presence of a title.
        for (id, title, expectedValue) in [
            ("time-breakdown-visits", "Visits remaining", "5 min"),
            ("time-breakdown-travel", "Travel remaining", ""),
            ("time-breakdown-waiting", "Free time before appointments", ""),
            ("time-breakdown-reducible", "Visit time that can be shortened", "0 min")
        ] {
            let texts = app.staticTexts.matching(identifier: id)
            reveal(texts.firstMatch, app: app)
            let rowText = texts.allElementsBoundByIndex.map { element in
                [element.label, element.value as? String ?? ""].joined(separator: " ")
            }.joined(separator: " ")
            XCTAssertTrue(rowText.contains(title), "Each timing component needs its own explanation")
            if !expectedValue.isEmpty {
                XCTAssertTrue(rowText.contains(expectedValue), "Timing breakdown must use this trip’s fixed five-minute allocation")
            } else {
                XCTAssertTrue(rowText.contains("Unknown") || rowText.range(of: "[0-9]", options: .regularExpression) != nil,
                              "Travel and appointment waiting must show an estimate or explicitly say Unknown")
            }
        }
        attachScreenshot("Scheduled trip timing breakdown", app: app)

        // SwiftUI Label exposes both its symbol and text with this identifier; assert the text.
        let conflict = app.staticTexts["schedule-conflict-status"].firstMatch
        let overrun = app.staticTexts["schedule-overrun"]
        reveal(conflict, app: app)
        expectLabel(conflict, contains: "Schedule doesn’t fit")
        reveal(overrun, app: app)
        XCTAssertTrue(overrun.label.range(of: "[0-9]", options: .regularExpression) != nil,
                      "The selected start and appointment must explain the amount of schedule overrun")

        let dinner = app.buttons["place-row-1"]
        reveal(dinner, app: app)
        expectLabel(dinner, contains: "Allocated 5 min")
        expectLabel(dinner, contains: "Fixed 5 min")

        // A second run still asks for a time; the template did not acquire the first run's date.
        tapVisible(app.buttons["Schedule another trip"], app: app)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(timeQuestions.count, 2)
        app.buttons["Cancel"].tap()
    }

    func testNotificationsExplainEventsAndAllNoneControls() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Garden", app: app)
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
        tapVisible(app.buttons["Notifications"], app: app)
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        let start = app.switches["notification-trip-start"]
        let arrival = app.switches["notification-arrivals"]
        expectLabel(start, contains: "Before trip starts")
        XCTAssertEqual(start.value as? String, "0")
        reveal(arrival, app: app)
        expectLabel(arrival, contains: "When you arrive")
        XCTAssertEqual(arrival.value as? String, "0")
        let departure = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Before leaving Garden")).firstMatch
        reveal(departure, app: app)
        XCTAssertEqual(departure.value as? String, "0")
        XCTAssertFalse(app.buttons["notifications-none"].isEnabled)
        app.buttons["notifications-all"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        reveal(start, app: app)
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        reveal(arrival, app: app)
        XCTAssertEqual(arrival.value as? String, "1")
        reveal(departure, app: app)
        XCTAssertEqual(departure.value as? String, "1")
        XCTAssertFalse(app.buttons["notifications-all"].isEnabled)
        app.buttons["notifications-none"].tap()
        reveal(start, app: app)
        expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: start)
        waitForExpectations(timeout: 5)
        reveal(arrival, app: app)
        XCTAssertEqual(arrival.value as? String, "0")
        reveal(departure, app: app)
        XCTAssertEqual(departure.value as? String, "0")
        XCTAssertFalse(app.buttons["notifications-none"].isEnabled)
    }

    func testArrivalOvershootConfigurationEditAndRelaunchPreserveHistory() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("First place", app: app)
        addPlace("Second place", app: app, latitude: "35.4800")
        scheduleAndStart(app)
        setPosition(latitude: "35.4676", longitude: "-97.5164", app: app)
        let name = app.staticTexts["arrival-name"]
        expectLabel(name, contains: "First place")
        expectLabel(app.staticTexts["places-progress"], contains: "1")
        let nextFrame = app.buttons["next-place"].frame
        XCTAssertLessThanOrEqual(app.frame.maxX - nextFrame.maxX, 36, "Next stays near the right edge")
        XCTAssertGreaterThan(nextFrame.midX, app.frame.midX)

        setPosition(latitude: "35.4700", longitude: "-97.5164", app: app)
        XCTAssertTrue(symbol("compass-arrow", app: app).waitForExistence(timeout: 5))
        expectLabel(name, contains: "First place")
        XCTAssertEqual(app.buttons["next-place"].frame.minY, nextFrame.minY, accuracy: 1,
                       "Overshooting changes the hero symbol without moving navigation controls")
        let heading = app.sliders["simulator-heading"]
        let arrow = symbol("compass-arrow", app: app)
        let initialAngle = arrow.label
        heading.adjust(toNormalizedSliderPosition: 0.5)
        let changedAngle = NSPredicate(format: "label != %@", initialAngle)
        expectation(for: changedAngle, evaluatedWith: arrow)
        waitForExpectations(timeout: 5)

        openTripDetails(app)
        tapVisible(app.buttons["place-row-1"], app: app)
        replace(app.textFields["place-name"], with: "First place renamed", app: app)
        setSwitch(app.switches["shared-entry-area"], enabled: false, app: app)
        tapVisible(app.buttons["edit-explore-area"], app: app)
        ensureCoordinatesExpanded(app)
        replace(app.textFields["latitude"], with: "35.4730", app: app)
        app.buttons["save-location"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        setPosition(latitude: "35.4700", longitude: "-97.5164", app: app)
        app.sliders["simulator-heading"].adjust(toNormalizedSliderPosition: 0)
        expectLabel(symbol("compass-arrow", app: app), contains: "0 degrees")
        expectLabel(name, contains: "First place renamed")
        expectLabel(app.staticTexts["places-progress"], contains: "1")
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-home"].waitForExistence(timeout: 8))
        expectLabel(name, contains: "First place renamed")
        expectLabel(app.staticTexts["places-progress"], contains: "1")
    }

    func testArrivalMapStaysRevealedThroughOvershootAndHistoryAndOpensAppleMaps() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("First map place", app: app, latitude: "35.5000")
        addPlace("Second map place", app: app, latitude: "35.5100")
        scheduleAndStart(app)
        setPosition(latitude: "35.4900", longitude: "-97.5164", app: app)
        app.buttons["Simulator location"].tap()

        let arrivalMap = app.buttons["arrival-map"]
        XCTAssertFalse(arrivalMap.exists, "An unreached place must not reveal its map")
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        let approachingCompass = symbol("compass-arrow", app: app)
        XCTAssertTrue(approachingCompass.waitForExistence(timeout: 5))
        let approachingFrame = approachingCompass.frame
        let nextY = app.buttons["next-place"].frame.minY
        // The hero is anchored to the full screen, independent of safe areas or header height.
        XCTAssertEqual(approachingFrame.midY, app.frame.midY, accuracy: 1,
                       "The compass must be vertically centered on the screen")
        XCTAssertEqual(approachingFrame.midX, app.frame.midX, accuracy: 1,
                       "The compass must be horizontally centered on the screen")
        attachScreenshot("Centered approaching compass", app: app)

        // Apply the inside position with coarse accuracy first, so typing cannot trigger the
        // arrival transition behind the keyboard. A fresh precise sample then records arrival.
        app.buttons["Simulator location"].tap()
        let accuracy = app.segmentedControls.containing(.button, identifier: "±300 m").firstMatch
        XCTAssertTrue(accuracy.waitForExistence(timeout: 5))
        accuracy.buttons["±300 m"].tap()
        setPosition(latitude: "35.5000", longitude: "-97.5164", app: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Apply must dismiss the coordinate keyboard before arrival")
        XCTAssertFalse(arrivalMap.exists, "A coarse sample cannot confirm arrival inside a smaller Entry radius")
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        expectLabel(app.staticTexts["places-progress"], contains: "0/2")
        accuracy.buttons["±3 m"].tap()
        expectLabel(app.staticTexts["arrival-name"], contains: "First map place")
        expectLabel(arrivalMap, contains: "Open First map place in Apple Maps")
        app.buttons["Simulator location"].tap()
        let footerSettled = NSPredicate { _, _ in
            abs(app.buttons["next-place"].frame.minY - nextY) <= 1
        }
        expectation(for: footerSettled, evaluatedWith: app.buttons["next-place"])
        waitForExpectations(timeout: 5)
        let arrivedFrame = arrivalMap.frame
        XCTAssertEqual(arrivedFrame.midY, approachingFrame.midY, accuracy: 1,
                       "The arrival map replaces the compass in the same hero space")
        XCTAssertEqual(arrivedFrame.midX, approachingFrame.midX, accuracy: 1)
        XCTAssertEqual(arrivedFrame.height, 240, accuracy: 1)
        XCTAssertEqual(app.buttons["next-place"].frame.minY, nextY, accuracy: 1,
                       "Arrival must not shift the navigation controls")

        setPosition(latitude: "35.5030", longitude: "-97.5164", app: app)
        app.buttons["Simulator location"].tap()
        XCTAssertTrue(symbol("compass-arrow", app: app).waitForExistence(timeout: 5))
        expectLabel(arrivalMap, contains: "Open First map place in Apple Maps")
        expectLabel(app.staticTexts["arrival-name"], contains: "First map place")
        XCTAssertEqual(arrivalMap.frame.midY, arrivedFrame.midY, accuracy: 1)
        XCTAssertEqual(arrivalMap.frame.midX, arrivedFrame.midX, accuracy: 1)
        XCTAssertEqual(arrivalMap.frame.height, arrivedFrame.height, accuracy: 1,
                       "Return guidance overlays the map without resizing its hero space")
        XCTAssertEqual(app.buttons["next-place"].frame.minY, nextY, accuracy: 1,
                       "Overshooting must not shift the navigation controls")

        // Return inside the shared Exit before Next, so the engine starts the approach to the
        // unreached second stop. Revealed content belongs to its visit, not the entire run.
        setPosition(latitude: "35.5000", longitude: "-97.5164", app: app)
        app.buttons["Simulator location"].tap()
        app.buttons["next-place"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: arrivalMap)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        XCTAssertTrue(symbol("compass-arrow", app: app).waitForExistence(timeout: 5))
        XCTAssertEqual(symbol("compass-arrow", app: app).frame.midY, approachingFrame.midY, accuracy: 1,
                       "The next approach returns to the same centered compass position")
        XCTAssertEqual(symbol("compass-arrow", app: app).frame.midX, approachingFrame.midX, accuracy: 1)
        XCTAssertEqual(app.buttons["next-place"].frame.minY, nextY, accuracy: 1)
        expectLabel(app.staticTexts["places-progress"], contains: "1/2")

        for cycle in 1...2 {
            app.buttons["previous-place"].tap()
            XCTAssertTrue(app.staticTexts["Previous visit"].waitForExistence(timeout: 5))
            expectLabel(app.staticTexts["arrival-name"], contains: "First map place")
            expectLabel(arrivalMap, contains: "Open First map place in Apple Maps")
            let resume = app.buttons["resume-navigation"]
            let reviewSettled = NSPredicate { _, _ in
                arrivalMap.exists && resume.exists &&
                abs(arrivalMap.frame.midY - app.frame.midY) <= 1 &&
                abs(arrivalMap.frame.midX - app.frame.midX) <= 1 &&
                abs(resume.frame.minY - nextY) <= 1
            }
            expectation(for: reviewSettled, evaluatedWith: arrivalMap)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(arrivalMap.frame.midY, app.frame.midY, accuracy: 1,
                           "Back must show the previous map in the same centered hero")
            XCTAssertEqual(arrivalMap.frame.midX, app.frame.midX, accuracy: 1)
            XCTAssertEqual(resume.frame.minY, nextY, accuracy: 1)
            XCTAssertEqual(app.buttons["previous-place"].frame.minY, nextY, accuracy: 1)
            expectLabel(app.staticTexts["places-progress"], contains: "1/2")
            XCTAssertFalse(app.staticTexts["Second map place"].exists,
                           "Reviewing history must not reveal the unreached destination")
            attachScreenshot("Centered Back review cycle \(cycle)", app: app)

            resume.tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: arrivalMap)
            waitForExpectations(timeout: 5)
            let resumedCompass = symbol("compass-arrow", app: app)
            XCTAssertTrue(resumedCompass.waitForExistence(timeout: 5))
            let navigationSettled = NSPredicate { _, _ in
                abs(resumedCompass.frame.midY - app.frame.midY) <= 1 &&
                abs(resumedCompass.frame.midX - app.frame.midX) <= 1 &&
                abs(app.buttons["next-place"].frame.minY - nextY) <= 1
            }
            expectation(for: navigationSettled, evaluatedWith: resumedCompass)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(resumedCompass.frame.midY, app.frame.midY, accuracy: 1,
                           "Resume must return to the same centered compass")
            XCTAssertEqual(resumedCompass.frame.midX, app.frame.midX, accuracy: 1)
            XCTAssertEqual(app.buttons["next-place"].frame.minY, nextY, accuracy: 1)
            XCTAssertEqual(app.buttons["previous-place"].frame.minY, nextY, accuracy: 1)
            XCTAssertFalse(app.staticTexts["arrival-name"].exists)
            XCTAssertFalse(app.staticTexts["Second map place"].exists,
                           "Resume must keep the next destination hidden until arrival")
            expectLabel(app.staticTexts["places-progress"], contains: "1/2")
            attachScreenshot("Centered Resume navigation cycle \(cycle)", app: app)
        }

        setPosition(latitude: "35.5100", longitude: "-97.5164", app: app)
        expectLabel(app.staticTexts["arrival-name"], contains: "Second map place")
        expectLabel(arrivalMap, contains: "Open Second map place in Apple Maps")
        app.buttons["Simulator location"].tap()
        attachScreenshot("Revealed destination arrival map", app: app)

        // Opening the place uses the real installed Maps app; no route or message is sent.
        tapVisible(arrivalMap, app: app)
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 10),
                      "Tapping the arrival map must open the destination in Apple Maps")
        attachScreenshot("Arrival map opened Apple Maps", app: maps)
    }

    func testNextCompletesRunAndAnotherRunStartsWithoutOldProgress() {
        let app = launchFresh()
        openTemplate(app)
        addPlace("Only place", app: app)
        scheduleAndStart(app)
        setPosition(latitude: "35.4676", longitude: "-97.5164", app: app)
        expectLabel(app.staticTexts["arrival-name"], contains: "Only place")
        app.buttons["Simulator location"].tap()
        app.buttons["next-place"].tap()
        XCTAssertTrue(app.staticTexts["trip-complete"].waitForExistence(timeout: 5))
        expectLabel(app.staticTexts["places-progress"], contains: "1/1")
        app.buttons["previous-place"].tap()
        XCTAssertTrue(app.staticTexts["Previous visit"].waitForExistence(timeout: 5))
        expectLabel(app.staticTexts["arrival-name"], contains: "Only place")
        let historyMap = app.buttons["arrival-map"]
        expectLabel(historyMap, contains: "Open Only place in Apple Maps")
        let historyCentered = NSPredicate { _, _ in
            abs(historyMap.frame.midY - app.frame.midY) <= 1 &&
            abs(historyMap.frame.midX - app.frame.midX) <= 1
        }
        expectation(for: historyCentered, evaluatedWith: historyMap)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(historyMap.frame.midY, app.frame.midY, accuracy: 1)
        XCTAssertEqual(historyMap.frame.midX, app.frame.midX, accuracy: 1)
        expectLabel(app.staticTexts["places-progress"], contains: "1/1")
        app.buttons["resume-navigation"].tap()
        XCTAssertTrue(app.staticTexts["trip-complete"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: historyMap)
        waitForExpectations(timeout: 5)
        expectLabel(app.staticTexts["places-progress"], contains: "1/1")
        openTripDetails(app)
        tapVisible(app.buttons["Schedule another trip"], app: app)
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
        XCTAssertFalse(app.staticTexts["trip-complete"].exists)
        // The schedule summary fills the first viewport; materialize the native lazy row
        // before checking that the new run retained its place without its old visit status.
        let newRunPlace = app.buttons["place-row-1"]
        reveal(newRunPlace, app: app)
        expectLabel(newRunPlace, contains: "Only place")
        XCTAssertFalse(newRunPlace.label.contains("Visited"))
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "60"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 10))
        return app
    }

    private func openTemplate(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["My adventure"].firstMatch.waitForExistence(timeout: 8))
        app.staticTexts["My adventure"].firstMatch.tap()
        XCTAssertTrue(app.buttons["add-place"].waitForExistence(timeout: 5))
    }

    private func addPlace(_ name: String, app: XCUIApplication,
                          latitude: String = "35.4676", longitude: String = "-97.5164") {
        beginAddingPlace(name, app: app, latitude: latitude, longitude: longitude)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["add-place"].exists)
    }

    /// Add starts with the full place editor; its sole location popup edits the map and coordinates.
    private func beginAddingPlace(_ name: String, app: XCUIApplication,
                                  latitude: String = "35.4676", longitude: String = "-97.5164") {
        tapVisible(app.buttons["add-place"], app: app)
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-place"].isEnabled)
        tapVisible(app.textFields["place-name"], app: app)
        app.textFields["place-name"].typeText(name)
        XCTAssertFalse(app.buttons["save-place"].isEnabled, "An alias alone does not invent a location")
        tapVisible(app.buttons["place-area-map"], app: app)
        XCTAssertTrue(app.descendants(matching: .any)["location-map"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-location"].isEnabled)
        ensureCoordinatesExpanded(app)
        tapVisible(app.textFields["latitude"], app: app)
        app.textFields["latitude"].typeText(latitude)
        tapVisible(app.textFields["longitude"], app: app)
        app.textFields["longitude"].typeText(longitude)
        XCTAssertTrue(app.buttons["save-location"].isEnabled)
        app.buttons["save-location"].tap()
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-place"].isEnabled)
        XCTAssertEqual(app.textFields["place-name"].value as? String, name)
    }

    private func scheduleAndStart(_ app: XCUIApplication) {
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["save-scheduled-trip"].waitForExistence(timeout: 5))
        app.buttons["save-scheduled-trip"].tap()
        expectLabel(app.buttons["open-compass"], contains: "Start trip")
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.buttons["Simulator location"].waitForExistence(timeout: 8))
    }

    private func setPosition(latitude: String, longitude: String, app: XCUIApplication) {
        if !app.buttons["apply-simulator-position"].exists { app.buttons["Simulator location"].tap() }
        replace(app.textFields["simulator-latitude"], with: latitude, app: app)
        replace(app.textFields["simulator-longitude"], with: longitude, app: app)
        app.buttons["apply-simulator-position"].tap()
    }

    private func openHome(_ app: XCUIApplication) {
        app.buttons["open-home"].tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 1) {
            app.alerts.buttons["Open Home"].tap()
        }
        XCTAssertTrue(app.buttons["new-plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-settings"].exists)
    }

    private func openTripDetails(_ app: XCUIApplication) {
        openHome(app)
        let active = app.buttons["active-trip-details"]
        if active.exists { tapVisible(active, app: app) }
        else {
            let completed = app.cells.containing(.staticText, identifier: "Completed").firstMatch
            XCTAssertTrue(completed.waitForExistence(timeout: 5))
            tapVisible(completed, app: app)
        }
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
    }

    private func ensureCoordinatesExpanded(_ app: XCUIApplication) {
        if !app.textFields["latitude"].exists {
            let coordinates = app.buttons["Coordinates"]
            XCTAssertTrue(coordinates.waitForExistence(timeout: 5))
            coordinates.tap()
        }
        XCTAssertTrue(app.textFields["latitude"].waitForExistence(timeout: 5))
    }

    private func expectCoordinateFields(latitude: Double, longitude: Double, app: XCUIApplication) {
        ensureCoordinatesExpanded(app)
        let latitudeField = app.textFields["latitude"]
        let longitudeField = app.textFields["longitude"]
        reveal(latitudeField, app: app)
        XCTAssertEqual(Double(latitudeField.value as? String ?? "") ?? .nan, latitude, accuracy: 0.000001)
        reveal(longitudeField, app: app)
        XCTAssertEqual(Double(longitudeField.value as? String ?? "") ?? .nan, longitude, accuracy: 0.000001)
    }

    private func setSwitch(_ toggle: XCUIElement, enabled: Bool, app: XCUIApplication) {
        reveal(toggle, app: app)
        let expected = enabled ? "1" : "0"
        if toggle.value as? String != expected {
            let nativeSwitch = toggle.switches.firstMatch
            if nativeSwitch.exists { nativeSwitch.tap() } else { toggle.tap() }
        }
        expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }

    private func replace(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        tapVisible(field, app: app)
        let placeholder = field.placeholderValue ?? ""
        // Observed on this iOS simulator: triple tap selects the entire single-line paragraph.
        // Cut is exposed as text in the native edit menu, so match its label across element types.
        field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let cut = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cut")).firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 3), "Native selection must expose Cut before replacing text")
        cut.tap()
        let cleared = field.value as? String ?? ""
        XCTAssertTrue(cleared.isEmpty || cleared == placeholder, "Cut must remove the complete old value before typing")
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Replace must update the field itself before the test continues")
    }

    private func symbol(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        var directionUp = true
        var hasSeenTarget = false
        var reversedAfterDisappearance = false
        for _ in 0..<12 {
            let viewport = visibleContentBounds(app)
            var distance: CGFloat = 150
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= viewport.lowerBound && frame.maxY <= viewport.upperBound { return }
                hasSeenTarget = true
                reversedAfterDisappearance = false
                directionUp = frame.minY >= viewport.lowerBound
                let obscuredDistance = directionUp ? frame.maxY - viewport.upperBound : viewport.lowerBound - frame.minY
                distance = min(150, max(60, obscuredDistance + 24))
            } else if hasSeenTarget && !reversedAfterDisappearance {
                // A recycled List row disappearing after a drag means we passed it. Reverse
                // once and keep that direction until it is observed again, rather than fling on.
                directionUp.toggle()
                reversedAfterDisappearance = true
            }
            if let done = keyboardDone(app) {
                // Finish editing before moving to an offscreen field. The native keyboard
                // accessory floats above XCUIKeyboard.frame and consumes drags begun on it.
                done.tap()
                continue
            }
            scrollContent(app, viewport: viewport, upward: directionUp, distance: distance)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        let viewport = visibleContentBounds(app)
        XCTAssertGreaterThanOrEqual(element.frame.minY, viewport.lowerBound, "Target must be below fixed navigation before tapping")
        XCTAssertLessThanOrEqual(element.frame.maxY, viewport.upperBound, "Target must be above fixed footer/keyboard before tapping")
    }

    private func scrollContent(_ app: XCUIApplication, viewport: ClosedRange<CGFloat>, upward: Bool, distance: CGFloat) {
        // Drag only the Form/List outside an embedded map. A map consumes the same gesture to
        // pan its camera, so scrolling through the screen's midpoint can silently edit geometry.
        let identifiedMaps = ["place-area-map", "location-map"].compactMap { id -> CGRect? in
            let element = app.descendants(matching: .any)[id].firstMatch
            return element.exists ? element.frame : nil
        }
        let maps = app.maps.allElementsBoundByIndex.filter(\.exists).map(\.frame) + identifiedMaps
        let candidateX = [app.frame.minX + app.frame.width * 0.75, app.frame.minX + 8, app.frame.maxX - 8]
        var lane: (x: CGFloat, lower: CGFloat, upper: CGFloat)?
        for x in candidateX {
            var segments = [(lower: viewport.lowerBound + 12, upper: viewport.upperBound - 12)]
            for map in maps where x >= map.minX - 4 && x <= map.maxX + 4 {
                segments = segments.flatMap { segment -> [(lower: CGFloat, upper: CGFloat)] in
                    if map.maxY + 12 <= segment.lower || map.minY - 12 >= segment.upper { return [segment] }
                    var remaining: [(lower: CGFloat, upper: CGFloat)] = []
                    if map.minY - 12 > segment.lower { remaining.append((segment.lower, map.minY - 12)) }
                    if map.maxY + 12 < segment.upper { remaining.append((map.maxY + 12, segment.upper)) }
                    return remaining
                }
            }
            if let best = segments.max(by: { $0.upper - $0.lower < $1.upper - $1.lower }), best.upper - best.lower >= 60 {
                lane = (x, best.lower, best.upper)
                break
            }
        }
        guard let lane else {
            XCTFail("No visible Form/List region outside the map is available for scrolling")
            return
        }
        let travel = min(distance, lane.upper - lane.lower - 8)
        let middle = (lane.lower + lane.upper) / 2
        let startY = middle + (upward ? travel / 2 : -travel / 2)
        let endY = middle + (upward ? -travel / 2 : travel / 2)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: lane.x - app.frame.minX, dy: startY - app.frame.minY))
        let end = origin.withOffset(CGVector(dx: lane.x - app.frame.minX, dy: endY - app.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    private func visibleContentBounds(_ app: XCUIApplication) -> ClosedRange<CGFloat> {
        let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).map { $0.frame.maxY }.max()
        // Only the configuration's Places view picker is a fixed list header. Radius units
        // inside a Form are ordinary scrollable controls, not an obstruction above that Form.
        let placesView = app.segmentedControls["Places view"]
        let segmentBottom: CGFloat? = placesView.exists && placesView.isHittable ? placesView.frame.maxY : nil
        var top = max(app.frame.minY + 64, max(navigationBottom ?? 0, segmentBottom ?? 0))
        // StopEditor's map is a fixed sibling above its Form, unlike PlaceEditor's inline
        // preview. A scrolled Form row behind that map must be revealed downward, not upward.
        let fixedMap = app.descendants(matching: .any)["location-map"].firstMatch
        if fixedMap.exists && fixedMap.isHittable { top = max(top, fixedMap.frame.maxY) }
        var bottom = app.frame.maxY - 44
        let footer = app.buttons["open-compass"].firstMatch
        if footer.exists && footer.isHittable { bottom = min(bottom, footer.frame.minY - 20) }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            bottom = min(bottom, keyboard.frame.minY - 8)
            if let done = keyboardDone(app) { bottom = min(bottom, done.frame.minY - 8) }
        }
        return top...max(top, bottom)
    }

    private func keyboardDone(_ app: XCUIApplication) -> XCUIElement? {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return nil }
        let keyboardTop = keyboard.frame.minY
        return app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first { button in
            guard button.isHittable else { return false }
            let frame = button.frame
            return frame.minY >= keyboardTop - 90 && frame.maxY <= keyboardTop + 4
        }
    }

    private func tapVisible(_ element: XCUIElement, app: XCUIApplication) {
        reveal(element, app: app)
        element.tap()
    }

    private func expectLabel(_ element: XCUIElement, contains text: String) {
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 8)
    }
}
