import XCTest

final class ConfigurationTests: XCTestCase {
    func testAppearanceCanBeChangedAndPersistsAfterRelaunch() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        app.buttons["plan-options"].tap()
        app.buttons["appearance-settings"].tap()
        XCTAssertTrue(app.buttons["accent-purple"].waitForExistence(timeout: 5))
        app.buttons["accent-purple"].tap()
        XCTAssertEqual(app.buttons["accent-purple"].value as? String, "Selected")
        let hex = app.textFields["custom-color-hex"]
        hex.tap()
        hex.press(forDuration: 1.2)
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        else { hex.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6)) }
        hex.typeText("7C5CFC")
        app.buttons["apply-custom-color"].tap()
        XCTAssertEqual(app.switches["use-custom-color"].value as? String, "1")
        app.segmentedControls.buttons["Pointer"].tap()
        app.buttons["icon-kite"].tap()
        XCTAssertEqual(app.buttons["icon-kite"].value as? String, "Selected")
        app.segmentedControls.buttons["Border"].tap()
        app.buttons["border-doubleRing"].tap()
        XCTAssertEqual(app.buttons["border-doubleRing"].value as? String, "Selected")
        app.buttons["appearance-done"].tap()
        app.terminate()
        app.launch()
        app.buttons["plan-options"].tap()
        app.buttons["appearance-settings"].tap()
        XCTAssertTrue(app.textFields["custom-color-hex"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["custom-color-hex"].value as? String, "7C5CFC")
        XCTAssertEqual(app.switches["use-custom-color"].value as? String, "1")
        app.segmentedControls.buttons["Pointer"].tap()
        XCTAssertEqual(app.buttons["icon-kite"].value as? String, "Selected")
        app.segmentedControls.buttons["Border"].tap()
        XCTAssertEqual(app.buttons["border-doubleRing"].value as? String, "Selected")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Appearance settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSimulatorPreviewRotatesAndArrivesWithoutChangingSavedProgress() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("First place", app: app, hint: "Follow the smell of pancakes.")
        add("Second place", app: app)
        app.terminate()
        app.launch()
        app.buttons["open-compass"].tap()
        let heading = app.sliders["preview-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["places-progress"].label, "0 of 2 places visited")
        let completion = app.descendants(matching: .any)["estimated-completion"].firstMatch
        let hasEstimate = NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "Est. finish", "unavailable")
        expectation(for: hasEstimate, evaluatedWith: completion)
        waitForExpectations(timeout: 5)
        let arrow = app.otherElements["compass-arrow"]
        XCTAssertEqual(arrow.label, "Compass pointing to your next place")
        XCTAssertEqual(app.staticTexts["navigation-hint"].label, "Follow the smell of pancakes.")
        let proximity = app.otherElements["distance-temperature"]
        XCTAssertTrue(proximity.exists)
        XCTAssertEqual(proximity.label, "0.75 mi")
        XCTAssertEqual(proximity.value as? String, "Warm")
        app.buttons["preview-outside"].tap()
        XCTAssertEqual(proximity.label, "0.25 mi")
        XCTAssertEqual(proximity.value as? String, "Hot")
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        let initialHeading = arrow.value as? String
        heading.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(arrow.value as? String, initialHeading)
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        let backY = app.buttons["back-stop"].frame.minY
        let configurationY = app.buttons["open-configuration"].frame.minY
        let distanceY = proximity.frame.minY
        app.buttons["preview-inside"].tap()
        XCTAssertTrue(app.otherElements["arrival-symbol"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["arrival-name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["places-progress"].label, "1 of 2 places visited")
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "First place")
        XCTAssertTrue(proximity.exists)
        XCTAssertEqual(app.buttons["back-stop"].frame.minY, backY, accuracy: 1)
        XCTAssertEqual(app.buttons["open-configuration"].frame.minY, configurationY, accuracy: 1)
        XCTAssertEqual(proximity.frame.minY, distanceY, accuracy: 1)
        let continueFrame = app.buttons["continue-stop"].frame
        let nameFrame = app.staticTexts["arrival-name"].frame
        XCTAssertFalse(app.staticTexts["navigation-hint"].exists)
        app.buttons["preview-outside"].tap()
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["places-progress"].label, "1 of 2 places visited")
        XCTAssertTrue(proximity.exists)
        XCTAssertFalse(app.otherElements["arrival-symbol"].exists)
        XCTAssertEqual(app.buttons["continue-stop"].frame, continueFrame)
        XCTAssertEqual(app.staticTexts["arrival-name"].frame, nameFrame)
        XCTAssertEqual(app.buttons["back-stop"].frame.minY, backY, accuracy: 1)
        XCTAssertEqual(proximity.frame.minY, distanceY, accuracy: 1)
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "First place")
        let returnHeading = arrow.value as? String
        heading.adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertNotEqual(arrow.value as? String, returnHeading)
        XCTAssertTrue(app.buttons["continue-stop"].isHittable)
        app.buttons["preview-inside"].tap()
        XCTAssertFalse(arrow.exists)
        XCTAssertTrue(app.otherElements["arrival-symbol"].exists)
        XCTAssertEqual(app.buttons["continue-stop"].frame, continueFrame)
        XCTAssertEqual(app.staticTexts["arrival-name"].frame, nameFrame)
        app.buttons["continue-stop"].tap()
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["navigation-hint"].exists)
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        app.buttons["preview-inside"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "Second place")
        app.buttons["back-stop"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "First place")
        XCTAssertEqual(app.staticTexts["places-progress"].label, "2 of 2 places visited")
        XCTAssertTrue(app.descendants(matching: .any)["visit-complete"].firstMatch.exists)
        XCTAssertTrue(app.buttons["continue-stop"].isHittable)
        app.buttons["preview-inside"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "First place")
        app.buttons["open-configuration"].tap()
        app.alerts["Open configuration?"].buttons["Open configuration"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["open-compass"].label, "Open compass")
        app.buttons["open-compass"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Simulator compass preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAddEditReorderAndPersist() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        let first = "Lunch"
        let second = "Garden walk"
        add(first, app: app)
        add(second, app: app)
        XCTAssertTrue(app.staticTexts[first].exists)
        XCTAssertTrue(app.staticTexts[second].exists)
        app.buttons["reorder"].tap()
        let from = app.cells.containing(.staticText, identifier: second).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5))
        let to = app.cells.containing(.staticText, identifier: first).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.1))
        from.press(forDuration: 0.5, thenDragTo: to)
        app.buttons["reorder"].tap()
        XCTAssertLessThan(app.staticTexts[second].frame.minY, app.staticTexts[first].frame.minY)
        app.staticTexts[first].tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" edited")
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts[first + " edited"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[first + " edited"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[first + " edited"].isHittable)
        XCTAssertLessThan(app.staticTexts[second].frame.minY, app.staticTexts[first + " edited"].frame.minY)
        app.buttons["plan-options"].tap()
        app.buttons["reset-progress"].tap()
        let alert = app.alerts["Reset progress?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        app.buttons["settings-done"].tap()
        XCTAssertTrue(app.staticTexts[first + " edited"].exists)
        app.buttons["plan-options"].tap()
        app.buttons["reset-progress"].tap()
        alert.buttons["Reset"].tap()
        app.buttons["settings-done"].tap()
        XCTAssertLessThan(app.staticTexts[second].frame.minY, app.staticTexts[first + " edited"].frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Configuration with saved places"
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    func testSearchFocusWorksOnFirstTapIncludingSearchIcon() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        for attempt in 0..<3 {
            app.buttons["add-place"].tap()
            let field = app.descendants(matching: .any)["place-search"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            if attempt == 1 {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
            } else { field.tap() }
            field.typeText("jam")
            XCTAssertEqual(field.value as? String, "jam")
            field.buttons.firstMatch.tap()
            field.typeText("park")
            XCTAssertEqual(field.value as? String, "park")
            app.buttons["Cancel"].tap()
        }
    }

    func testConfigurationPINAndExitFromFirstStopAndCompletion() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Surprise destination", app: app)
        app.buttons["open-compass"].tap()
        app.buttons["back-stop"].tap()
        XCTAssertTrue(app.alerts["Open configuration?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Surprise destination"].exists)
        app.buttons["open-configuration"].tap()
        app.alerts.buttons["Open configuration"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["plan-options"].tap()
        app.buttons["configuration-pin-settings"].tap()
        app.secureTextFields["new-configuration-pin"].tap()
        app.secureTextFields["new-configuration-pin"].typeText("0426")
        app.secureTextFields["confirm-configuration-pin"].tap()
        app.secureTextFields["confirm-configuration-pin"].typeText("0426")
        app.buttons["save-configuration-pin"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.secureTextFields["unlock-configuration-pin"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Surprise destination"].exists)
        enterPIN("0426", app: app)
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        app.buttons["back-stop"].tap()
        enterPIN("0000", app: app)
        XCTAssertTrue(app.staticTexts["incorrect-pin"].exists)
        XCTAssertFalse(app.staticTexts["Surprise destination"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.otherElements["compass-arrow"].waitForExistence(timeout: 5))
        app.buttons["preview-inside"].tap()
        app.buttons["continue-stop"].tap()
        XCTAssertTrue(app.staticTexts["trip-complete"].waitForExistence(timeout: 5))
        app.buttons["back-stop"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "Surprise destination")
        app.buttons["continue-stop"].tap()
        app.buttons["finished-configuration"].tap()
        enterPIN("0426", app: app)
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.buttons["open-compass"].tap()
        app.buttons["open-configuration"].tap()
        XCTAssertTrue(app.secureTextFields["unlock-configuration-pin"].waitForExistence(timeout: 5))
        app.buttons["forgot-configuration-pin"].tap()
        app.alerts["Remove PIN and show places?"].buttons["Remove PIN"].tap()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["open-compass"].waitForExistence(timeout: 5))
    }


    func testArrivalInstructionsEditOrderPersistAndRevealOnlyOnArrival() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Lunch", app: app)
        add("Walk", app: app)
        app.staticTexts["Lunch"].tap()
        app.buttons["add-instruction"].tap()
        let first = app.textFields["instruction-field-0"]
        first.tap(); first.typeText("Order something sweet.")
        app.buttons["add-instruction"].tap()
        let second = app.textFields["instruction-field-1"]
        second.tap(); second.typeText("Go to the patio.")
        app.buttons["instruction-options-1"].tap()
        app.buttons["Move up"].tap()
        XCTAssertEqual(app.textFields["instruction-field-0"].value as? String, "Go to the patio.")
        app.buttons["add-instruction"].tap()
        app.buttons["instruction-options-2"].tap()
        app.buttons["Delete instruction"].tap()
        app.buttons["save-place"].tap()
        app.terminate()
        app.launch()
        app.staticTexts["Lunch"].tap()
        XCTAssertEqual(app.textFields["instruction-field-0"].value as? String, "Go to the patio.")
        XCTAssertEqual(app.textFields["instruction-field-1"].value as? String, "Order something sweet.")
        app.buttons["Cancel"].tap()
        app.buttons["open-compass"].tap()
        XCTAssertFalse(app.staticTexts["arrival-instruction-0"].exists)
        app.buttons["preview-inside"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "Lunch")
        XCTAssertEqual(app.staticTexts["arrival-instruction-0"].label, "Step 1. Go to the patio.")
        XCTAssertEqual(app.staticTexts["arrival-instruction-1"].label, "Step 2. Order something sweet.")
        XCTAssertLessThan(app.staticTexts["arrival-instruction-0"].frame.minY, app.staticTexts["arrival-instruction-1"].frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Arrival instructions"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["preview-outside"].tap()
        XCTAssertTrue(app.otherElements["compass-arrow"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "Lunch")
        XCTAssertEqual(app.staticTexts["arrival-instruction-0"].label, "Step 1. Go to the patio.")
        XCTAssertEqual(app.staticTexts["arrival-instruction-1"].label, "Step 2. Order something sweet.")
        XCTAssertTrue(app.buttons["continue-stop"].isHittable)
        let returnAttachment = XCTAttachment(screenshot: app.screenshot())
        returnAttachment.name = "Guidance after driving past arrival"
        returnAttachment.lifetime = .keepAlways
        add(returnAttachment)
        app.buttons["continue-stop"].tap()
        XCTAssertFalse(app.staticTexts["arrival-instruction-0"].exists)
        app.buttons["preview-inside"].tap()
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "Walk")
        XCTAssertFalse(app.staticTexts["arrival-instruction-0"].exists)
        app.buttons["back-stop"].tap()
        app.buttons["preview-inside"].tap()
        XCTAssertEqual(app.staticTexts["arrival-instruction-0"].label, "Step 1. Go to the patio.")
    }

    func testSettingsOpensRepeatedly() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        for _ in 0..<4 {
            app.buttons["plan-options"].tap()
            XCTAssertTrue(app.buttons["appearance-settings"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["configuration-pin-settings"].exists)
            app.buttons["settings-done"].tap()
        }
    }

    func testGPSAccuracyGatesGuidanceAndArrivalWithoutHidingRevealedDetails() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("GPS destination", app: app)
        app.buttons["open-compass"].tap()
        XCTAssertTrue(app.otherElements["compass-arrow"].waitForExistence(timeout: 5))
        let backFrame = app.buttons["back-stop"].frame
        XCTAssertTrue(app.staticTexts["gps-accuracy"].label.contains("Arrival 100 ft"))
        app.segmentedControls.buttons["Poor GPS"].tap()
        // Coarse GPS still supports a bearing while the uncertainty circles are far apart.
        XCTAssertTrue(app.otherElements["compass-arrow"].exists)
        XCTAssertTrue(app.otherElements["distance-temperature"].exists)
        XCTAssertEqual(app.buttons["back-stop"].frame, backFrame)
        app.buttons["preview-inside"].tap()
        XCTAssertTrue(app.otherElements["gps-search-symbol"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["compass-arrow"].exists)
        XCTAssertFalse(app.otherElements["distance-temperature"].exists)
        XCTAssertFalse(app.staticTexts["arrival-name"].exists)
        app.segmentedControls.buttons["Good GPS"].tap()
        XCTAssertTrue(app.otherElements["arrival-symbol"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "GPS destination")
        let arrow = app.otherElements["compass-arrow"]
        app.buttons["preview-past"].tap()
        XCTAssertTrue(arrow.waitForExistence(timeout: 5))
        XCTAssertEqual(arrow.value as? String, "180 degrees")
        app.buttons["preview-outside"].tap()
        XCTAssertEqual(arrow.value as? String, "0 degrees")
        let nameFrame = app.staticTexts["arrival-name"].frame
        let continueFrame = app.buttons["continue-stop"].frame
        app.segmentedControls.buttons["Poor GPS"].tap()
        XCTAssertTrue(app.otherElements["gps-search-symbol"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["compass-arrow"].exists)
        XCTAssertFalse(app.otherElements["arrival-symbol"].exists)
        XCTAssertEqual(app.staticTexts["arrival-name"].frame, nameFrame)
        XCTAssertEqual(app.buttons["continue-stop"].frame, continueFrame)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Searching for accurate GPS after arrival"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["preview-outside"].tap()
        app.segmentedControls.buttons["Good GPS"].tap()
        XCTAssertTrue(app.otherElements["compass-arrow"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["arrival-name"].label, "GPS destination")
    }

    func testMapLocationAndRadiusPersistAndCancelDiscardsChanges() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        app.buttons["add-place"].tap()
        app.buttons["choose-on-map"].tap()
        let map = app.otherElements["location-map"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["use-map-location"].isEnabled)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)).tap()
        XCTAssertTrue(app.staticTexts["map-selected-coordinates"].waitForExistence(timeout: 5))
        let firstCoordinate = app.staticTexts["map-selected-coordinates"].label
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.6)).tap()
        let selectedCoordinate = app.staticTexts["map-selected-coordinates"].label
        XCTAssertNotEqual(firstCoordinate, selectedCoordinate)
        app.sliders["map-radius"].adjust(toNormalizedSliderPosition: 0.35)
        let selectedRadius = app.staticTexts["map-radius-value"].label
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Map pin and arrival radius"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["use-map-location"].tap()
        let name = app.textFields["place-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Map destination")
        app.buttons["save-place"].tap()
        app.terminate(); app.launch()
        app.staticTexts["Map destination"].tap()
        app.buttons["adjust-on-map"].tap()
        XCTAssertTrue(app.staticTexts["map-radius-value"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["map-radius-value"].label, selectedRadius)
        XCTAssertEqual(app.staticTexts["map-selected-coordinates"].label, selectedCoordinate)
        app.sliders["map-radius"].adjust(toNormalizedSliderPosition: 0.8)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        app.buttons["cancel-map"].tap()
        app.buttons["adjust-on-map"].tap()
        XCTAssertEqual(app.staticTexts["map-radius-value"].label, selectedRadius)
        XCTAssertEqual(app.staticTexts["map-selected-coordinates"].label, selectedCoordinate)
    }

    func testStopsMapShowsNumberedPlacesAndFitsAllAfterPanning() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        let mode = app.segmentedControls["places-view"]
        mode.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["No places added"].waitForExistence(timeout: 5))
        mode.buttons["List"].tap()
        add("Lunch", app: app)
        add("Park", app: app, latitude: "35.4822", longitude: "-97.5283")
        add("Dinner", app: app, latitude: "35.4497", longitude: "-97.5362")
        mode.buttons["Map"].tap()
        let map = app.otherElements["stops-overview-map"]
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        func assertPinsVisible() {
            for number in 1...3 {
                let pin = app.descendants(matching: .any)["overview-stop-\(number)"].firstMatch
                XCTAssertTrue(pin.waitForExistence(timeout: 5))
                XCTAssertTrue(map.frame.contains(pin.frame), "Place \(number) should be fully inside the map")
            }
        }
        assertPinsVisible()
        map.swipeLeft()
        app.buttons["fit-all-stops"].tap()
        assertPinsVisible()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Muted tilted map with numbered stops"
        attachment.lifetime = .keepAlways
        add(attachment)
        mode.buttons["List"].tap()
        XCTAssertTrue(app.buttons["stop-0"].waitForExistence(timeout: 5))
        app.buttons["reorder"].tap()
        XCTAssertTrue(app.buttons["reorder"].exists)
        mode.buttons["Map"].tap()
        XCTAssertTrue(app.buttons["add-place"].waitForExistence(timeout: 5))
        XCTAssertTrue(map.exists)
    }

    func testTravelRowsSwitchModeAndKeepSavedEstimates() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchEnvironment["COMPASS_UI_TEST_ETA_SECONDS"] = "600"
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Lunch", app: app)
        add("Park", app: app)
        XCTAssertTrue(app.staticTexts["10–12 min"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["Walk"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Walk"].isSelected)
        app.segmentedControls.buttons["Bike"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Bike"].isSelected)
        XCTAssertTrue(app.staticTexts["10–12 min"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["total-time"].label, "20–22 min")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Travel-time row between destinations"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "COMPASS_UI_TEST_ETA_SECONDS")
        app.launch()
        XCTAssertTrue(app.segmentedControls.buttons["Bike"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Bike"].isSelected)
        XCTAssertTrue(app.staticTexts["10–12 min"].exists)
        XCTAssertEqual(app.staticTexts["total-time"].label, "20–22 min")
    }

    func testVisitDurationEditsAndPersists() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Lunch", app: app, duration: "15")
        app.buttons["stop-0"].tap()
        let duration = app.textFields["visit-duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        focusVisible(duration, app: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["duration-done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        duration.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        duration.typeText("30")
        XCTAssertEqual(duration.value as? String, "30")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Editing time here with native number pad"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["duration-done"].tap()
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["stop-0"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["stop-0"].tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.value as? String, "30.0")
        focusVisible(duration, app: app)
        duration.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["duration-done"].tap()
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["stop-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["100 ft radius · 5 min here"].exists)
    }

    func testOptionalArrivalDeadlineSavesCancelsAndRemoves() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Dinner", app: app)
        XCTAssertFalse(app.staticTexts["latest-start"].exists)
        app.buttons["stop-0"].tap()
        let enabled = app.switches["arrival-deadline-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
        focusVisible(enabled.switches.firstMatch, app: app)
        let picker = app.descendants(matching: .any)["arrival-deadline"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Optional arrival deadline with native date and time picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["save-place"].tap()
        let latest = app.staticTexts["latest-start"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        let savedStart = latest.label
        app.terminate()
        app.launch()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertEqual(latest.label, savedStart)
        app.buttons["stop-0"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "1")
        focusVisible(enabled.switches.firstMatch, app: app)
        XCTAssertFalse(picker.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertEqual(latest.label, savedStart)
        app.buttons["stop-0"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "1")
        focusVisible(enabled.switches.firstMatch, app: app)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.buttons["stop-0"].waitForExistence(timeout: 5))
        XCTAssertFalse(latest.exists)
        app.terminate()
        app.launch()
        app.buttons["stop-0"].tap()
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
    }

    func testVisitCountdownUsesDurationAndShowsRunningBehind() {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["COMPASS_UI_TEST_DATA"] = UUID().uuidString
        app.launchArguments = ["-adventureOpen", "NO"]
        app.launch()
        add("Quick stop", app: app, duration: "0.02")
        app.buttons["open-compass"].tap()
        XCTAssertFalse(app.otherElements["visit-countdown"].exists)
        app.buttons["preview-inside"].tap()
        XCTAssertTrue(app.staticTexts["arrival-name"].waitForExistence(timeout: 5))
        let countdown = app.descendants(matching: .any)["visit-countdown"].firstMatch
        let overdue = NSPredicate(format: "label CONTAINS %@", "Running behind")
        expectation(for: overdue, evaluatedWith: countdown)
        waitForExpectations(timeout: 6)
        app.buttons["preview-outside"].tap()
        XCTAssertTrue(app.otherElements["compass-arrow"].waitForExistence(timeout: 5))
        XCTAssertTrue(countdown.label.contains("Running behind"))
        XCTAssertTrue(app.buttons["continue-stop"].isHittable)
    }

    private func focusVisible(_ field: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 {
            // Form creates offscreen rows lazily; scroll them into the hierarchy before reading their frame.
            if !field.exists { app.swipeUp(); continue }
            let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY - 40
            let frame = field.frame
            if field.isHittable, frame.minY > 150, frame.maxY < keyboardTop - 8 { break }
            if frame.minY <= 150 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(field.isHittable)
        field.tap()
    }

    private func enterPIN(_ pin: String, app: XCUIApplication) {
        let field = app.secureTextFields["unlock-configuration-pin"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(pin)
        app.buttons["unlock-configuration"].tap()
    }

    private func add(_ name: String, app: XCUIApplication, hint: String? = nil, duration: String? = nil, latitude latitudeText: String = "35.4676", longitude longitudeText: String = "-97.5164") {
        app.buttons["add-place"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["place-search"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["latitude"].exists)
        app.buttons["enter-coordinates"].tap()
        if !app.buttons["save-place"].waitForExistence(timeout: 2), app.buttons["enter-coordinates"].exists {
            app.buttons["enter-coordinates"].tap()
        }
        XCTAssertTrue(app.buttons["save-place"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-place"].isEnabled)
        let field = app.textFields["place-name"]
        field.tap(); field.typeText(name)
        if let hint {
            let hintField = app.textFields["place-hint"]
            hintField.tap(); hintField.typeText(hint)
        }
        if let duration {
            let field = app.textFields["visit-duration"]
            field.tap(); field.typeText(duration)
            app.buttons["duration-done"].tap()
        }
        let latitude = app.textFields["latitude"]
        focusVisible(latitude, app: app); latitude.typeText(latitudeText)
        let longitude = app.textFields["longitude"]
        focusVisible(longitude, app: app); longitude.typeText(longitudeText)
        app.buttons["save-place"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }
}
