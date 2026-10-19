import XCTest
@testable import KeyphoreCore

final class VIAAdapterTests: XCTestCase {
    func testVIAConfigurationExposesFortyOneEffectsAndStaticSpeed() {
        XCTAssertEqual(SupportedKeyboardModel.air75V2.supportedEffects(for: .backlight).count, 41)
        XCTAssertTrue(SupportedKeyboardModel.air75V2.supportsSpeed(for: .backlightStatic))
    }

    func testEveryVIAEffectUsesItsExactIDAndIndependentReadbackWithoutRepeatedWrites() throws {
        for (id, effect) in NativeLightingEffect.viaCatalog.enumerated() {
            let discovery = VIADiscovery(devices: [v2()])
            discovery.transport.effect = id == 0 ? 4 : 0
            let adapter = NuPhyIOAdapter(discovery: discovery)
            let appearance = ZoneAppearance(effect: effect, color: SignalColor(red: 0, green: 255, blue: 174),
                brightness: SignalBrightness(percent: 30)!, speed: LightingSpeed(level: 4)!)
            let behavior = LightingBehavior(backlight: .signal(appearance), strip: .unmanaged)
            let evidence = try adapter.applyAndVerify(behavior)
            XCTAssertEqual(evidence.mainState[1], UInt8(id))
            XCTAssertTrue(discovery.transport.writes.contains { Array($0.prefix(4)) == [7, 3, 2, UInt8(id)] })
            if id == 0 {
                XCTAssertEqual(discovery.transport.writes.count, 1)
                XCTAssertTrue(behavior.isOff)
            } else {
                XCTAssertEqual(evidence.mainState, [75, UInt8(id), 255, 114, 255])
                XCTAssertTrue(discovery.transport.writes.contains { Array($0.prefix(4)) == [7, 3, 3, 255] })
            }
            let writes = discovery.transport.writes.count
            XCTAssertTrue(try adapter.displays(behavior))
            _ = try adapter.applyAndVerify(behavior)
            XCTAssertEqual(discovery.transport.writes.count, writes)
            XCTAssertTrue(discovery.transport.sent.allSatisfy { $0.count == 32 && [1, 7, 8].contains($0[0]) })
            XCTAssertTrue(discovery.transport.sent.filter { $0[0] != 1 }.allSatisfy { $0[1] == 3 })
        }
    }

    func testEveryNonOffVIAEffectAcceptsBoundedLowBrightnessQuantization() throws {
        for effect in NativeLightingEffect.viaCatalog where !effect.isOff {
            let discovery = VIADiscovery(devices: [v2()])
            let adapter = NuPhyIOAdapter(discovery: discovery)
            let behavior = LightingBehavior(backlight: .signal(ZoneAppearance(effect: effect,
                color: SignalColor(red: 0, green: 255, blue: 0), brightness: SignalBrightness(percent: 1)!)), strip: .unmanaged)
            XCTAssertNoThrow(try adapter.apply(behavior))
            XCTAssertEqual(discovery.transport.brightness, 1)
            let writes = discovery.transport.writes.count
            XCTAssertTrue(try adapter.displays(behavior))
            try adapter.apply(behavior)
            XCTAssertEqual(discovery.transport.writes.count, writes)
        }
    }

    func testV3RejectsEveryVIAOnlyEffectBeforeOpeningOrSendingForAllEntryPoints() {
        let v3 = HIDDeviceDescriptor(id: "v3", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0)
        for effect in NativeLightingEffect.viaCatalog where effect.wireID == nil {
            let behavior = LightingBehavior(backlight: .signal(ZoneAppearance(effect: effect,
                color: SignalColor(red: 0, green: 255, blue: 0))), strip: .unmanaged)
            for operation in 0..<3 {
                let discovery = VIADiscovery(devices: [v3])
                let adapter = NuPhyIOAdapter(discovery: discovery)
                XCTAssertThrowsError(try {
                    switch operation {
                    case 0: try adapter.validate(behavior)
                    case 1: try adapter.apply(behavior)
                    default: _ = try adapter.displays(behavior)
                    }
                }()) {
                    XCTAssertEqual($0 as? NuPhyIOAdapterError, .unsupportedEffect)
                }
                XCTAssertEqual(discovery.opens, 0)
                XCTAssertTrue(discovery.transport.sent.isEmpty)
            }
        }
    }

    func testWiredV2RawInterfaceIsRecognized() {
        XCTAssertEqual(SupportedKeyboardModel.identify(v2())?.rawValue, "Air75 V2")
    }

    func testInspectionOnlyQueriesV2AndNeverOpensItsProtocolOnV3() throws {
        let discovery = VIADiscovery(devices: [v2()])
        let adapter = NuPhyIOAdapter(discovery: discovery)
        XCTAssertEqual(try adapter.inspectAir75V2State(), [255, 0, 139, 122, 254])
        XCTAssertEqual(discovery.transport.sent.map { $0[0] }, [1, 8, 8, 8, 8])
        adapter.invalidateTransport()
        discovery.devices = [HIDDeviceDescriptor(id: "v3", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0)]
        XCTAssertThrowsError(try adapter.inspectAir75V2State())
        XCTAssertEqual(discovery.transport.sent.count, 5)
    }

    func testMixedV2AndV3RefusesSelection() {
        let v3 = HIDDeviceDescriptor(id: "v3", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0)
        XCTAssertThrowsError(try Air65DeviceSelector.select(from: [v2(), v3])) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .ambiguous)
        }
    }

    func testExplicitV2TargetWorksAlongsideV3ButDoesNotFallBackWhenV2Disappears() throws {
        let v3 = HIDDeviceDescriptor(id: "v3", vendorID: 0x19f5, productID: 0x1028,
            product: "Air75 V3", bus: .usb, interfaceNumber: 3, usagePage: 1, usage: 0)
        let discovery = VIADiscovery(devices: [v2(), v3])
        let adapter = NuPhyIOAdapter(discovery: discovery)
        try adapter.selectTarget(.air75V2)
        try adapter.apply(.signal(LocalProfile.default.execution))
        XCTAssertEqual(adapter.connectedModel, .air75V2)
        let sent = discovery.transport.sent.count
        discovery.devices = [v3]
        XCTAssertThrowsError(try adapter.displays(.off))
        XCTAssertEqual(discovery.transport.sent.count, sent)
        XCTAssertEqual(adapter.selectedModel, .air75V2)
    }

    func testRejectsDongleWrongUsageWirelessAndDuplicateV2BeforeOpen() {
        for mutation in 0..<5 {
            var device = v2()
            switch mutation {
            case 0: device.productID = 0x3247
            case 1: device.bus = .bluetooth
            case 2: device.usagePage = 1
            case 3: device.usage = 6
            default: device.product = "Unknown firmware"
            }
            let discovery = VIADiscovery(devices: [device])
            XCTAssertThrowsError(try NuPhyIOAdapter(discovery: discovery).apply(.off))
            XCTAssertEqual(discovery.opens, 0)
        }
        let discovery = VIADiscovery(devices: [v2(), v2()])
        XCTAssertThrowsError(try NuPhyIOAdapter(discovery: discovery).apply(.off))
        XCTAssertEqual(discovery.opens, 0)
    }

    func testEnablePrecedesHSVAndIndependentReadbackVerifiesNativeBreathing() throws {
        let discovery = VIADiscovery(devices: [v2()])
        let adapter = NuPhyIOAdapter(discovery: discovery)
        let evidence = try adapter.applyAndVerify(.signal(LocalProfile.default.execution))
        XCTAssertEqual(adapter.connectedModel, .air75V2)
        XCTAssertTrue(evidence.protocolReadbackSucceeded)
        XCTAssertTrue(evidence.unmanagedZonesPreserved)
        XCTAssertEqual(evidence.unmanagedZoneProtection, .untouchedProtocolChannel)
        XCTAssertEqual(evidence.rhythmBefore, [])
        XCTAssertEqual(evidence.mainState, [253, 4, 153, 170, 255])
        XCTAssertEqual(discovery.transport.writes.map { Array($0.prefix(5)) }, [
            [7, 3, 2, 4, 0], [7, 3, 1, 0, 0], [7, 3, 4, 170, 255],
            [7, 3, 3, 153, 0], [7, 3, 1, 255, 0],
        ])
        XCTAssertEqual(discovery.transport.sent.suffix(4).map { Array($0.prefix(3)) },
                       [[8, 3, 1], [8, 3, 2], [8, 3, 3], [8, 3, 4]])
        let writes = discovery.transport.writes.count
        XCTAssertTrue(try adapter.displays(.signal(LocalProfile.default.execution)))
        _ = try adapter.applyAndVerify(.signal(LocalProfile.default.execution))
        XCTAssertEqual(discovery.transport.writes.count, writes)
        XCTAssertTrue(discovery.transport.sent.allSatisfy { $0.count == 32 && [1, 7, 8].contains($0[0]) })
    }

    func testRecordedThirtyPercentReadbackVerifiesWithoutRepeatedWrites() throws {
        let discovery = recordedIdleDiscovery()
        let adapter = NuPhyIOAdapter(discovery: discovery)
        let evidence = try adapter.applyAndVerify(recordedIdleBehavior)
        XCTAssertEqual(evidence.mainState, [76, 4, 255, 114, 255])
        XCTAssertTrue(evidence.protocolReadbackSucceeded)
        XCTAssertTrue(discovery.transport.writes.contains { Array($0.prefix(4)) == [7, 3, 1, 77] })
        let writes = discovery.transport.writes.count
        for _ in 0..<3 {
            XCTAssertTrue(try adapter.displays(recordedIdleBehavior))
            _ = try adapter.applyAndVerify(recordedIdleBehavior)
        }
        XCTAssertEqual(discovery.transport.writes.count, writes, "Stable quantized readback must not trigger dim/rewrite cycles")
        XCTAssertFalse(discovery.transport.sent.contains { $0[0] == 9 })
    }

    func testBrightnessToleranceIsBoundedToOneRoundedPercentStep() throws {
        for brightness: UInt8 in [74, 75, 76, 77, 78, 79, 80] {
            let adapter = NuPhyIOAdapter(discovery: recordedIdleDiscovery(after: [brightness, 4, 255, 114, 255]))
            XCTAssertNoThrow(try adapter.apply(recordedIdleBehavior), "Readback \(brightness) should be within 3/255 of SET 77")
        }
        for brightness: UInt8 in [0, 73, 81, 100, 253, 255] {
            let adapter = NuPhyIOAdapter(discovery: recordedIdleDiscovery(after: [brightness, 4, 255, 114, 255]))
            XCTAssertThrowsError(try adapter.apply(recordedIdleBehavior)) {
                XCTAssertEqual($0 as? VIAProtocolError, .readbackMismatch)
            }
        }
    }

    func testBrightnessToleranceDoesNotRelaxEffectColorSpeedOrOffVerification() throws {
        for state: [UInt8] in [
            [76, 1, 255, 114, 255], [76, 4, 254, 114, 255],
            [76, 4, 255, 113, 255], [76, 4, 255, 114, 254],
        ] {
            let adapter = NuPhyIOAdapter(discovery: recordedIdleDiscovery(after: state))
            XCTAssertThrowsError(try adapter.apply(recordedIdleBehavior)) {
                XCTAssertEqual($0 as? VIAProtocolError, .readbackMismatch)
            }
        }
        let adapter = NuPhyIOAdapter(discovery: recordedIdleDiscovery())
        try adapter.apply(recordedIdleBehavior)
        XCTAssertFalse(try adapter.displays(.off))
        XCTAssertThrowsError(try adapter.apply(.off)) {
            XCTAssertEqual($0 as? VIAProtocolError, .readbackMismatch)
        }
    }

    func testStaticColorAndOffPreserveUnrelatedValuesWithoutSave() throws {
        let discovery = VIADiscovery(devices: [v2()])
        discovery.transport.effect = 4
        let adapter = NuPhyIOAdapter(discovery: discovery)
        let behavior = LightingBehavior.signal(LocalProfile.default.completion)
        _ = try adapter.applyAndVerify(behavior)
        XCTAssertEqual(discovery.transport.effect, 1)
        XCTAssertEqual(discovery.transport.color, [85, 255])
        XCTAssertEqual(discovery.transport.speed, 153)
        XCTAssertEqual(discovery.transport.writes.first.map { Array($0.prefix(4)) }, [7, 3, 1, 0])
        let previousColor = discovery.transport.color
        let previousBrightness = discovery.transport.brightness
        let writes = discovery.transport.writes.count
        _ = try adapter.applyAndVerify(.off)
        XCTAssertEqual(discovery.transport.effect, 0)
        XCTAssertEqual(discovery.transport.color, previousColor)
        XCTAssertEqual(discovery.transport.brightness, previousBrightness)
        XCTAssertEqual(discovery.transport.writes.count, writes + 1)
        XCTAssertEqual(Array(discovery.transport.writes.last!.prefix(4)), [7, 3, 2, 0])
        XCTAssertFalse(discovery.transport.sent.contains { $0[0] == 9 })
    }

    func testUnsupportedCapabilitiesSendNoReportsAndKeepModelForSettings() {
        let invalid: [LightingBehavior] = [
            .off(for: .both), .off(for: .strip),
            LightingBehavior(backlight: .signal(ZoneAppearance(effect: .backlightWave,
                color: SignalColor(red: 0, green: 0, blue: 255))), strip: .unmanaged),
            LightingBehavior(backlight: .signal(ZoneAppearance(effect: .backlightStatic,
                color: SignalColor(red: 0, green: 0, blue: 255), colorMode: .multicolor)), strip: .unmanaged),
            LightingBehavior(backlight: .signal(ZoneAppearance(effect: .backlightBreathing,
                color: SignalColor(red: 0, green: 0, blue: 255), direction: .reverse)), strip: .unmanaged),
        ]
        for behavior in invalid {
            let discovery = VIADiscovery(devices: [v2()])
            let adapter = NuPhyIOAdapter(discovery: discovery)
            XCTAssertThrowsError(try adapter.apply(behavior)) {
                XCTAssertEqual(($0 as? LightingCapabilityError)?.model, .air75V2)
            }
            XCTAssertEqual(adapter.connectedModel, .air75V2)
            XCTAssertTrue(discovery.transport.sent.isEmpty)
        }
    }

    func testVersionAndReadbackFailuresReleaseTransportAndRecheckVersionOnRecovery() throws {
        let discovery = VIADiscovery(devices: [v2()])
        let adapter = NuPhyIOAdapter(discovery: discovery)
        discovery.transport.version = 13
        XCTAssertThrowsError(try adapter.apply(.off)) {
            XCTAssertEqual($0 as? VIAProtocolError, .unsupportedVersion(13))
        }
        XCTAssertNil(adapter.connectedModel)
        XCTAssertTrue(discovery.transport.writes.isEmpty)
        discovery.transport.version = 12
        discovery.transport.ignoreWrites = true
        XCTAssertThrowsError(try adapter.apply(.signal(LocalProfile.default.execution))) {
            XCTAssertEqual($0 as? VIAProtocolError, .readbackMismatch)
        }
        XCTAssertNil(adapter.connectedModel)
        discovery.transport.ignoreWrites = false
        try adapter.apply(.signal(LocalProfile.default.execution))
        XCTAssertEqual(discovery.opens, 3)
        XCTAssertEqual(discovery.resets, 2)
        XCTAssertEqual(discovery.transport.sent.filter { $0[0] == 1 }.count, 3)
    }

    func testCachedTransportDoesNotSurviveTopologyChangeAndWakeReopens() throws {
        let discovery = VIADiscovery(devices: [v2()])
        let adapter = NuPhyIOAdapter(discovery: discovery)
        try adapter.apply(.off)
        let count = discovery.transport.sent.count
        discovery.devices.append(v2())
        XCTAssertThrowsError(try adapter.displays(.off)) {
            XCTAssertEqual($0 as? Air65DeviceSelectionError, .ambiguous)
        }
        XCTAssertEqual(discovery.transport.sent.count, count)
        discovery.devices = [v2()]
        try adapter.apply(.off)
        adapter.invalidateTransport()
        try adapter.apply(.off)
        XCTAssertEqual(discovery.opens, 3)
    }

    func testMalformedResponseAndTimeoutCannotBecomeSuccessfulEvidence() {
        for response: [UInt8]? in [nil, [1], Array(repeating: 0xff, count: 32)] {
            let discovery = VIADiscovery(devices: [v2()])
            discovery.transport.overrideResponse = { _ in response }
            let adapter = NuPhyIOAdapter(discovery: discovery)
            XCTAssertThrowsError(try adapter.apply(.off))
            XCTAssertNil(adapter.connectedModel)
            XCTAssertTrue(discovery.transport.writes.isEmpty)
        }
    }

    func testHSVAndWireResponseValidation() throws {
        XCTAssertEqual(VIAProtocol.hsv(for: SignalColor(red: 255, green: 132, blue: 0)).hue, 22)
        XCTAssertEqual(VIAProtocol.hsv(for: SignalColor(red: 128, green: 128, blue: 128)).saturation, 0)
        XCTAssertEqual(VIAProtocol.hsv(for: SignalColor(red: 0, green: 0, blue: 0)).saturation, 0)
        let request = VIAProtocol.Request.get(.color)
        var wrong = try request.packet
        wrong[1] = 4
        XCTAssertThrowsError(try request.validate(wrong))
        wrong = try request.packet; wrong[2] = 2
        XCTAssertThrowsError(try request.validate(wrong))
        XCTAssertThrowsError(try request.validate(Array(request.packet.dropLast())))
        XCTAssertThrowsError(try request.validate(request.packet + [0]))
    }

    func testTransportFormatsKeepV3NormalizationAndStrictV2Descriptor() throws {
        let v2Report = Array(repeating: UInt8(0), count: 32)
        XCTAssertEqual(try HIDReportFormat.via.input(v2Report, reportID: 0), v2Report)
        XCTAssertThrowsError(try HIDReportFormat.via.input(v2Report, reportID: 1))
        XCTAssertThrowsError(try HIDReportFormat.via.input([0] + v2Report, reportID: 0))
        XCTAssertThrowsError(try HIDReportFormat.via.output(v2Report + [0]))
        let v3Report = Array(repeating: UInt8(0), count: 64)
        XCTAssertEqual(try HIDReportFormat.nuphy.input([0] + v3Report, reportID: 0), v3Report)
        XCTAssertEqual(try HIDReportFormat.nuphy.output(v3Report), v3Report)
        XCTAssertThrowsError(try HIDReportFormat.nuphy.output([0] + v3Report))
        try VIAProtocol.validateDescriptor(VIAProtocol.reportDescriptor, inputSize: 32, outputSize: 32)
        XCTAssertThrowsError(try VIAProtocol.validateDescriptor(VIAProtocol.reportDescriptor, inputSize: 64, outputSize: 32))
        XCTAssertThrowsError(try VIAProtocol.validateDescriptor([], inputSize: 32, outputSize: 32))
    }

    func testUnsupportedZonesDoNotAcquireOwnershipAndStillPermitQuit() throws {
        let fixture = try NativeLightingFixture(profile: .default.replacingControlledZones(.both))
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(0)))
        XCTAssertEqual(try fixture.ownership.load().zones, [])
        XCTAssertEqual(fixture.health.load(at: .milliseconds(0)), .connected(protocolHealthy: false, model: .air75V2))
        XCTAssertTrue(discovery.transport.sent.isEmpty)
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(100))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }

    func testUnsupportedEffectDoesNotPreventOwnedBacklightFromQuittingOff() throws {
        let unsupported = LocalProfile.default.execution.replacingAppearance(
            ZoneAppearance(effect: .backlightFlowing, color: SignalColor(red: 0, green: 0, blue: 255)), for: .backlight)
        let fixture = try NativeLightingFixture(profile: .default.replacingAppearance(unsupported, for: .execution))
        try fixture.signal()
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(0)))
        XCTAssertEqual(try fixture.ownership.load().zones, [.backlight])
        XCTAssertTrue(discovery.transport.sent.isEmpty)
        try fixture.quit.activate()
        try companion.sync(at: .milliseconds(100))
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(try fixture.ownership.load().zones, [])
    }

    func testPreviousV3StripOwnershipCannotBeSilentlyClearedOnV2() throws {
        let fixture = try NativeLightingFixture()
        try fixture.ownership.save(LightingOwnershipRecord(model: .air75V3, zones: [.strip, .backlight]))
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(0)))
        try fixture.quit.activate()
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))
        XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(try fixture.ownership.load().zones, [.strip, .backlight])
        XCTAssertTrue(discovery.transport.sent.isEmpty)
    }

    func testIdleAndWakeReplayLatestProfileAndQuitOverridesIdle() throws {
        let fixture = try NativeLightingFixture()
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        let recovery = CompanionRecoveryController(companion: companion)
        try recovery.poll(at: .milliseconds(0))
        XCTAssertEqual(discovery.transport.effect, 0)
        try recovery.handle(.willSleep, at: .milliseconds(100))
        let count = discovery.transport.sent.count
        try fixture.profiles.save(.default.replacingAppearance(LocalProfile.default.completion, forPreset: .idle))
        try recovery.poll(at: .milliseconds(200))
        XCTAssertEqual(discovery.transport.sent.count, count)
        try recovery.handle(.didWake, at: .milliseconds(300))
        try recovery.poll(at: .milliseconds(400))
        XCTAssertEqual(discovery.transport.effect, 1)
        XCTAssertEqual(discovery.opens, 2)
        XCTAssertTrue(try fixture.status.load().owners.isEmpty)
        try fixture.signal()
        try recovery.poll(at: .milliseconds(500))
        XCTAssertEqual(discovery.transport.effect, 4)
        try fixture.quit.activate()
        try recovery.poll(at: .milliseconds(600))
        XCTAssertEqual(discovery.transport.effect, 0)
        XCTAssertTrue(fixture.acknowledgement.isAcknowledged)
    }

    func testPreviewCanReplaceUnsupportedLiveEffectBeforeAnyEffectWrite() throws {
        let unsupported = LocalProfile.default.attention.replacingAppearance(
            ZoneAppearance(effect: .backlightFlowing, color: SignalColor(red: 255, green: 0, blue: 0)), for: .backlight)
        let fixture = try NativeLightingFixture(profile: .default.replacingAppearance(unsupported, for: .attention))
        try fixture.signal(.attention)
        _ = try fixture.preview.begin(at: .milliseconds(0))
        let discovery = VIADiscovery(devices: [v2()])
        try companion(fixture, discovery: discovery).sync(at: .milliseconds(0))
        XCTAssertEqual(try fixture.preview.load()?.phase, .presenting)
        XCTAssertEqual(discovery.transport.effect, 4)
    }

    func testDisconnectFailsActivePreviewAndExpiresOwnersBeforeHardwareValidation() throws {
        let fixture = try NativeLightingFixture()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        try companion.sync(at: .milliseconds(0))
        XCTAssertEqual(try fixture.preview.load()?.phase, .presenting)
        try fixture.status.recordSignal(ownerID: SignalOwnerID(product: "codex", sessionID: "expired", agentID: "main"),
            turnID: "turn", signal: .completion, expiresAt: .milliseconds(100),
            replacingSession: true, lockBudget: .milliseconds(100))
        try fixture.acknowledgement.acknowledge()
        discovery.devices = []
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(200)))
        XCTAssertEqual(try fixture.preview.load()?.phase, .failed)
        XCTAssertTrue(try fixture.status.load().owners.isEmpty)
        XCTAssertFalse(fixture.acknowledgement.isAcknowledged)
        XCTAssertEqual(fixture.health.load(at: .milliseconds(200)), .disconnected)
        discovery.devices = [v2()]
        try companion.sync(at: .milliseconds(300))
        XCTAssertEqual(discovery.transport.effect, 0)
    }

    func testValidationFailureDoesNotCancelPreviewRequestedDuringDiscovery() throws {
        let fixture = try NativeLightingFixture()
        _ = try fixture.preview.begin(at: .milliseconds(0))
        let discovery = VIADiscovery(devices: [v2()])
        let companion = companion(fixture, discovery: discovery)
        try companion.sync(at: .milliseconds(0))
        var replacement: SignalPreviewRecord?
        discovery.onDiscover = {
            replacement = try fixture.preview.begin(preset: .completion, at: .milliseconds(100))
        }
        discovery.devices = []
        XCTAssertThrowsError(try companion.sync(at: .milliseconds(100)))
        XCTAssertEqual(try fixture.preview.load()?.id, replacement?.id)
        XCTAssertEqual(try fixture.preview.load()?.phase, .pending)
    }

    private var recordedIdleBehavior: LightingBehavior {
        LightingBehavior(backlight: .signal(ZoneAppearance(effect: .backlightBreathing,
            color: SignalColor(red: 0, green: 255, blue: 174),
            brightness: SignalBrightness(percent: 30)!, speed: LightingSpeed(level: 4)!)), strip: .unmanaged)
    }

    private func recordedIdleDiscovery(after: [UInt8] = [76, 4, 255, 114, 255]) -> VIADiscovery {
        let discovery = VIADiscovery(devices: [v2()])
        var targetWasSent = false
        // Physical V2 probe, 2026-10-16: SET [7,3,1,77] -> GET [8,3,1,76].
        // Replay the recorded normalized states; do not derive them from a guessed firmware maximum.
        discovery.transport.overrideResponse = { report in
            if report[0] == 7 {
                if Array(report.prefix(4)) == [7, 3, 1, 77] { targetWasSent = true }
                return report // An echoed SET alone never proves the resulting state.
            }
            let prefix: [UInt8]
            if report[0] == 1 { prefix = [1, 0, 12] }
            else {
                XCTAssertEqual(Array(report.prefix(2)), [8, 3])
                let state: [UInt8] = targetWasSent ? after : [253, 4, 255, 114, 255]
                switch report[2] {
                case 1: prefix = [8, 3, 1, state[0]]
                case 2: prefix = [8, 3, 2, state[1]]
                case 3: prefix = [8, 3, 3, state[2]]
                case 4: prefix = [8, 3, 4, state[3], state[4]]
                default: XCTFail("Unexpected GET"); return nil
                }
            }
            return prefix + Array(repeating: 0, count: 32 - prefix.count)
        }
        return discovery
    }

    private func companion(_ fixture: NativeLightingFixture, discovery: VIADiscovery) -> KeyphoreCompanion {
        KeyphoreCompanion(store: fixture.status, profileProvider: { _ in try fixture.profiles.load() },
            lighting: NuPhyIOAdapter(discovery: discovery), keyboardHealthStore: fixture.health,
            previewStore: fixture.preview, signalOffAcknowledgement: fixture.acknowledgement,
            quitGate: fixture.quit, ownershipStore: fixture.ownership)
    }

    private func v2() -> HIDDeviceDescriptor {
        HIDDeviceDescriptor(id: "v2", vendorID: 0x19f5, productID: 0x3246,
            product: "NuPhy Air75 V2", bus: .usb, interfaceNumber: 1, usagePage: 0xff60, usage: 0x61)
    }
}

private final class VIADiscovery: Air65TransportDiscovering {
    var devices: [HIDDeviceDescriptor]
    let transport = VIATransport()
    var opens = 0
    var resets = 0
    var onDiscover: (() throws -> Void)?
    init(devices: [HIDDeviceDescriptor]) { self.devices = devices }
    func discover() throws -> [HIDDeviceDescriptor] {
        try onDiscover?()
        return devices
    }
    func open(_ descriptor: HIDDeviceDescriptor) throws -> any Air65ReportTransport {
        opens += 1
        return transport
    }
    func resetDiscoveryState() { resets += 1 }
}

// Independent firmware model: disabled HSV setters are ignored, SET echoes without proving a write.
private final class VIATransport: Air65ReportTransport {
    var version: UInt16 = 12
    var effect: UInt8 = 0
    var brightness: UInt8 = 128
    var speed: UInt8 = 139
    var color: [UInt8] = [122, 254]
    var ignoreWrites = false
    var overrideResponse: (([UInt8]) -> [UInt8]?)?
    var sent: [[UInt8]] = []
    var writes: [[UInt8]] { sent.filter { $0[0] == 7 } }
    private var response: [UInt8]?

    func send(_ report: [UInt8]) throws {
        sent.append(report)
        if let overrideResponse { response = overrideResponse(report); return }
        var reply = report
        if report[0] == 1 {
            reply[1] = UInt8(version >> 8); reply[2] = UInt8(truncatingIfNeeded: version)
        } else if report[0] == 8 {
            switch report[2] {
            case 1: reply[3] = UInt8(Int(brightness) * 255 / 128)
            case 2: reply[3] = effect
            case 3: reply[3] = speed
            case 4: reply[3] = color[0]; reply[4] = color[1]
            default: XCTFail("Unexpected GET")
            }
        } else if report[0] == 7, !ignoreWrites {
            switch report[2] {
            case 1: if effect != 0 { brightness = UInt8(Int(report[3]) / 2) }
            case 2: effect = report[3]
            case 3: speed = report[3]
            case 4: if effect != 0 { color = Array(report[3...4]) }
            default: XCTFail("Unexpected SET")
            }
        }
        response = reply
    }

    func receive(timeout: TimeInterval) throws -> [UInt8]? {
        defer { response = nil }
        return response
    }
}
