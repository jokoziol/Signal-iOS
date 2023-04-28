//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalMessaging
import SignalUI

enum LaunchPreflightError {
    case unknownDatabaseVersion
    case couldNotRestoreTransferredData
    case databaseCorruptedAndMightBeRecoverable
    case databaseUnrecoverablyCorrupted
    case lastAppLaunchCrashed
    case lowStorageSpaceAvailable

    var supportTag: String {
        switch self {
        case .unknownDatabaseVersion:
            return "LaunchFailure_UnknownDatabaseVersion"
        case .couldNotRestoreTransferredData:
            return "LaunchFailure_CouldNotRestoreTransferredData"
        case .databaseCorruptedAndMightBeRecoverable:
            return "LaunchFailure_DatabaseCorruptedAndMightBeRecoverable"
        case .databaseUnrecoverablyCorrupted:
            return "LaunchFailure_DatabaseUnrecoverablyCorrupted"
        case .lastAppLaunchCrashed:
            return "LaunchFailure_LastAppLaunchCrashed"
        case .lowStorageSpaceAvailable:
            return "LaunchFailure_NoDiskSpaceAvailable"
        }
    }
}

extension AppDelegate {
    // MARK: - App launch

    @objc
    func handleDidFinishLaunching(launchOptions: [UIApplication.LaunchOptionsKey: Any]) {
        let launchStartedAt = CACurrentMediaTime()

        // This should be the first thing we do.
        let mainAppContext = MainAppContext()
        SetCurrentAppContext(mainAppContext, false)

        enableLoggingIfNeeded()

        if CurrentAppContext().isRunningTests {
            _ = initializeWindow(mainAppContext: mainAppContext, rootViewController: UIViewController())
            return
        }

        Logger.warn("application: didFinishLaunchingWithOptions.")
        defer { Logger.info("application: didFinishLaunchingWithOptions completed.") }

        BenchEventStart(title: "Presenting HomeView", eventId: "AppStart", logInProduction: true)

        InstrumentsMonitor.enable()
        let monitorId = InstrumentsMonitor.startSpan(category: "appstart", parent: "application", name: "didFinishLaunchingWithOptions")
        defer { InstrumentsMonitor.stopSpan(category: "appstart", hash: monitorId) }

        #if DEBUG
        FeatureFlags.logFlags()
        DebugFlags.logFlags()
        #endif

        Cryptography.seedRandom()

        // This *must* happen before we try and access or verify the database,
        // since we may be in a state where the database has been partially
        // restored from transfer (e.g. the key was replaced, but the database
        // files haven't been moved into place)
        let didDeviceTransferRestoreSucceed = Bench(
            title: "Slow device transfer service launch",
            logIfLongerThan: 0.01,
            logInProduction: true,
            block: { DeviceTransferService.shared.launchCleanup() }
        )

        // XXX - careful when moving this. It must happen before we load GRDB.
        verifyDBKeysAvailableBeforeBackgroundLaunch()

        InstrumentsMonitor.trackEvent(name: "AppStart")

        // This must happen in appDidFinishLaunching or earlier to ensure we don't
        // miss notifications. Setting the delegate also seems to prevent us from
        // getting the legacy notification notification callbacks upon launch e.g.
        // 'didReceiveLocalNotification'
        UNUserNotificationCenter.current().delegate = self

        // If there's a notification, queue it up for processing. (This processing
        // may happen immediately, after a short delay, or never.)
        if let remoteNotification = launchOptions[.remoteNotification] as? NSDictionary {
            Logger.info("Application was launched by tapping a push notification.")
            processRemoteNotification(remoteNotification, completion: {})
        }

        // Do this even if `appVersion` isn't used -- there's side effects.
        let appVersion = AppVersion.shared

        // We need to do this _after_ we set up logging, when the keychain is unlocked,
        // but before we access the database or files on disk.
        let preflightError = checkIfAllowedToLaunch(
            mainAppContext: mainAppContext,
            appVersion: appVersion,
            didDeviceTransferRestoreSucceed: didDeviceTransferRestoreSucceed
        )

        if let preflightError {
            let viewController = terminalErrorViewController()
            let window = initializeWindow(mainAppContext: mainAppContext, rootViewController: viewController)
            showPreflightErrorUI(preflightError, window: window, viewController: viewController, launchStartedAt: launchStartedAt)
            return
        }

        // If this is a regular launch, increment the "launches attempted" counter.
        // If repeatedly start launching but never finish them (ie the app is
        // crashing while launching), we'll notice in `checkIfAllowedToLaunch`.
        let userDefaults = mainAppContext.appUserDefaults()
        let appLaunchesAttempted = userDefaults.integer(forKey: kAppLaunchesAttemptedKey)
        userDefaults.set(appLaunchesAttempted + 1, forKey: kAppLaunchesAttemptedKey)

        // Show LoadingViewController until the database migrations are complete.
        let window = initializeWindow(mainAppContext: mainAppContext, rootViewController: LoadingViewController())
        self.launchApp(in: window, launchStartedAt: launchStartedAt)
    }

    private func enableLoggingIfNeeded() {
        let isLoggingEnabled: Bool
        #if DEBUG
        isLoggingEnabled = true
        DebugLogger.shared().enableTTYLogging()
        #else
        isLoggingEnabled = OWSPreferences.isLoggingEnabled()
        #endif
        if isLoggingEnabled {
            DebugLogger.shared().enableFileLogging()
        }
        if DebugFlags.audibleErrorLogging {
            DebugLogger.shared().enableErrorReporting()
        }
        DebugLogger.configureSwiftLogging()
    }

    private func initializeWindow(mainAppContext: MainAppContext, rootViewController: UIViewController) -> UIWindow {
        let window = OWSWindow()
        self.window = window
        mainAppContext.mainWindow = window
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    private func launchApp(in window: UIWindow, launchStartedAt: CFTimeInterval) {
        assert(window.rootViewController is LoadingViewController)
        configureGlobalUI(in: window)
        setUpMainAppEnvironment().done(on: DispatchQueue.main) { (finalContinuation, sleepBlockObject) in
            self.didLoadDatabase(
                finalContinuation: finalContinuation,
                sleepBlockObject: sleepBlockObject,
                window: window,
                launchStartedAt: launchStartedAt
            )
        }
    }

    private func configureGlobalUI(in window: UIWindow) {
        Theme.setupSignalAppearance()

        let screenLockUI = OWSScreenLockUI.shared()
        let windowManager = OWSWindowManager.shared
        screenLockUI.setup(withRootWindow: window)
        windowManager.setup(withRootWindow: window, screenBlockingWindow: screenLockUI.screenBlockingWindow)
        screenLockUI.startObserving()
    }

    private func setUpMainAppEnvironment() -> Guarantee<(AppSetup.FinalContinuation, NSObject)> {
        let sleepBlockObject = NSObject()
        DeviceSleepManager.shared.addBlock(blockObject: sleepBlockObject)

        let databaseContinuation = AppSetup().start(
            appContext: CurrentAppContext(),
            paymentsEvents: PaymentsEventsMainApp(),
            mobileCoinHelper: MobileCoinHelperSDK(),
            webSocketFactory: WebSocketFactoryHybrid(),
            callMessageHandler: AppEnvironment.sharedCallMessageHandler,
            notificationPresenter: AppEnvironment.sharedNotificationPresenter
        )
        setupNSEInteroperation()
        SUIEnvironment.shared.setup()
        AppEnvironment.shared.setup()
        SignalApp.shared().setup()
        let result = databaseContinuation.prepareDatabase()
        OWSAnalytics.appLaunchDidBegin()
        return result.map(on: SyncScheduler()) { ($0, sleepBlockObject) }
    }

    private func checkSomeDiskSpaceAvailable() -> Bool {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .path
        let succeededCreatingDir = OWSFileSystem.ensureDirectoryExists(tempDir)

        // Best effort at deleting temp dir, which shouldn't ever fail
        if succeededCreatingDir && !OWSFileSystem.deleteFile(tempDir) {
            owsFailDebug("Failed to delete temp dir used for checking disk space!")
        }

        return succeededCreatingDir
    }

    private func setupNSEInteroperation() {
        Logger.info("")

        // We immediately post a notification letting the NSE know the main app has launched.
        // If it's running it should take this as a sign to terminate so we don't unintentionally
        // try and fetch messages from two processes at once.
        DarwinNotificationCenter.post(.mainAppLaunched)

        // We listen to this notification for the lifetime of the application, so we don't
        // record the returned observer token.
        DarwinNotificationCenter.addObserver(
            for: .nseDidReceiveNotification,
            queue: DispatchQueue.global(qos: .userInitiated)
        ) { token in
            Logger.debug("Handling NSE received notification")

            // Immediately let the NSE know we will handle this notification so that it
            // does not attempt to process messages while we are active.
            DarwinNotificationCenter.post(.mainAppHandledNotification)

            AppReadiness.runNowOrWhenAppDidBecomeReadySync {
                self.messageFetcherJob.run()
            }
        }
    }

    private func didLoadDatabase(
        finalContinuation: AppSetup.FinalContinuation,
        sleepBlockObject: NSObject,
        window: UIWindow,
        launchStartedAt: CFTimeInterval
    ) {
        Logger.info("")
        AssertIsOnMainThread()

        let regLoader = RegistrationCoordinatorLoaderImpl(dependencies: .from(self))

        // Before we mark ready, block message processing on any pending change numbers.
        let hasPendingChangeNumber = databaseStorage.read { transaction in
            regLoader.hasPendingChangeNumber(transaction: transaction.asV2Read)
        }
        if hasPendingChangeNumber {
            // The registration loader will clear the suspension later on.
            messagePipelineSupervisor.suspendMessageProcessingWithoutHandle(for: .pendingChangeNumber)
        }

        // If user is missing profile name, redirect to onboarding flow.
        if !profileManager.hasProfileName {
            databaseStorage.write { transaction in
                tsAccountManager.setIsOnboarded(false, transaction: transaction)
            }
        }

        let launchInterface = buildLaunchInterface(regLoader: regLoader)

        let hasInProgressRegistration: Bool
        switch launchInterface {
        case .registration, .deprecatedOnboarding:
            hasInProgressRegistration = true
        case .chatList:
            hasInProgressRegistration = false
        }

        switch finalContinuation.finish(willResumeInProgressRegistration: hasInProgressRegistration) {
        case .corruptRegistrationState:
            let viewController = terminalErrorViewController()
            window.rootViewController = viewController
            presentLaunchFailureActionSheet(
                from: viewController,
                launchStartedAt: launchStartedAt,
                supportTag: "CorruptRegistrationState",
                title: NSLocalizedString(
                    "APP_LAUNCH_FAILURE_CORRUPT_REGISTRATION_TITLE",
                    comment: "Title for an error indicating that the app couldn't launch because some unexpected error happened with the user's registration status."
                ),
                message: NSLocalizedString(
                    "APP_LAUNCH_FAILURE_CORRUPT_REGISTRATION_MESSAGE",
                    comment: "Message for an error indicating that the app couldn't launch because some unexpected error happened with the user's registration status."
                ),
                actions: [.submitDebugLogsAndCrash]
            )
        case nil:
            firstly {
                LaunchJobs.run(tsAccountManager: tsAccountManager, databaseStorage: databaseStorage)
            }.done(on: DispatchQueue.main) {
                self.setAppIsReady(launchInterface: launchInterface, launchStartedAt: launchStartedAt)
                DeviceSleepManager.shared.removeBlock(blockObject: sleepBlockObject)
            }
        }
    }

    private func setAppIsReady(launchInterface: LaunchInterface, launchStartedAt: CFTimeInterval) {
        Logger.info("")
        AssertIsOnMainThread()
        owsAssert(!AppReadiness.isAppReady)
        owsAssert(!CurrentAppContext().isRunningTests)

        // Note that this does much more than set a flag; it will also run all deferred blocks.
        AppReadiness.setAppIsReadyUIStillPending()

        CurrentAppContext().appUserDefaults().removeObject(forKey: kAppLaunchesAttemptedKey)

        if tsAccountManager.isRegistered {
            databaseStorage.read { transaction in
                let localAddress = self.tsAccountManager.localAddress(with: transaction)
                let deviceId = self.tsAccountManager.storedDeviceId(transaction: transaction)
                let deviceCount = OWSDevice.anyCount(transaction: transaction)
                let linkedDeviceMessage = deviceCount > 1 ? "\(deviceCount) devices including the primary" : "no linked devices"
                Logger.info("localAddress: \(String(describing: localAddress)), deviceId: \(deviceId) (\(linkedDeviceMessage))")
            }
        }

        if tsAccountManager.isRegisteredAndReady {
            // This should happen at any launch, background or foreground.
            SyncPushTokensJob.run()
        }

        if tsAccountManager.isRegisteredAndReady {
            APNSRotationStore.rotateIfNeededOnAppLaunchAndReadiness(performRotation: {
                SyncPushTokensJob.run(mode: .rotateIfEligible)
            }).map {
                // If the method returns a closure, run it after message processing.
                _ = messageProcessor.fetchingAndProcessingCompletePromise().done($0)
            }
        }

        DebugLogger.shared().postLaunchLogCleanup()
        AppVersion.shared.mainAppLaunchDidComplete()

        enableBackgroundRefreshIfNecessary()
        Self.updateApplicationShortcutItems(isRegisteredAndReady: tsAccountManager.isRegisteredAndReady)

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(registrationLockDidChange),
            name: Notification.Name(NSNotificationName_2FAStateDidChange),
            object: nil
        )

        if !Environment.shared.preferences.hasGeneratedThumbnails() {
            databaseStorage.asyncRead(
                block: { transaction in
                    TSAttachment.anyEnumerate(transaction: transaction, batched: true) { (_, _) in
                        // no-op. It's sufficient to initWithCoder: each object.
                    }
                },
                completion: {
                    Environment.shared.preferences.setHasGeneratedThumbnails(true)
                }
            )
        }

        checkDatabaseIntegrityIfNecessary(isRegistered: tsAccountManager.isRegistered)

        SignalApp.shared().showLaunchInterface(launchInterface, launchStartedAt: launchStartedAt)
    }

    private func enableBackgroundRefreshIfNecessary() {
        let interval: TimeInterval
        if OWS2FAManager.shared.isRegistrationLockEnabled, self.tsAccountManager.isRegisteredAndReady {
            // Ping server once a day to keep-alive reglock clients.
            interval = 24 * 60 * 60
        } else {
            interval = UIApplication.backgroundFetchIntervalNever
        }
        UIApplication.shared.setMinimumBackgroundFetchInterval(interval)
    }

    /// The user must unlock the device once after reboot before the database encryption key can be accessed.
    private func verifyDBKeysAvailableBeforeBackgroundLaunch() {
        guard UIApplication.shared.applicationState == .background else {
            return
        }
        if StorageCoordinator.hasGrdbFile && GRDBDatabaseStorageAdapter.isKeyAccessible {
            return
        }

        Logger.warn("Exiting because we are in the background and the database password is not accessible.")

        let notificationContent = UNMutableNotificationContent()
        notificationContent.body = String(
            format: NSLocalizedString(
                "NOTIFICATION_BODY_PHONE_LOCKED_FORMAT",
                comment: "Lock screen notification text presented after user powers on their device without unlocking. Embeds {{device model}} (either 'iPad' or 'iPhone')"
            ),
            UIDevice.current.localizedModel
        )

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil
        )

        let application: UIApplication = .shared
        let userNotificationCenter: UNUserNotificationCenter = .current()

        userNotificationCenter.removeAllPendingNotificationRequests()
        application.applicationIconBadgeNumber = 0

        userNotificationCenter.add(notificationRequest)
        application.applicationIconBadgeNumber = 1

        // Wait a few seconds for XPC calls to finish and for rate limiting purposes.
        Thread.sleep(forTimeInterval: 3)
        Logger.flush()
        exit(0)
    }

    // MARK: - Registration

    private func buildLaunchInterface(regLoader: RegistrationCoordinatorLoader) -> LaunchInterface {
        let onboardingController = Deprecated_OnboardingController()

        if let lastMode = databaseStorage.read(block: { regLoader.restoreLastMode(transaction: $0.asV2Read) }) {
            Logger.info("Found ongoing registration; continuing")
            return .registration(regLoader, lastMode)
            // TODO[Registration]: use a db migration to move isComplete state to reg coordinator.
        } else if !onboardingController.isComplete {
            if UIDevice.current.isIPad {
                return .deprecatedOnboarding(onboardingController)
            } else {
                let desiredMode: RegistrationMode
                if
                    let reregNumber = tsAccountManager.reregistrationPhoneNumber,
                    let reregE164 = E164(reregNumber),
                    let reregAci = tsAccountManager.reregistrationUUID
                {
                    Logger.info("Found legacy re-registration; continuing in new registration")
                    // A user who started re-registration before the new
                    // registration flow shipped; kick them to new re-reg.
                    desiredMode = .reRegistering(.init(e164: reregE164, aci: reregAci))
                } else {
                    Logger.info("Found legacy initial registration; continuing in new registration")
                    desiredMode = .registering
                }
                return .registration(regLoader, desiredMode)
            }
        } else {
            return .chatList(onboardingController)
        }
    }

    // MARK: - Launch failures

    private func checkIfAllowedToLaunch(
        mainAppContext: MainAppContext,
        appVersion: AppVersion,
        didDeviceTransferRestoreSucceed: Bool
    ) -> LaunchPreflightError? {
        guard checkSomeDiskSpaceAvailable() else {
            return .lowStorageSpaceAvailable
        }

        guard didDeviceTransferRestoreSucceed else {
            return .couldNotRestoreTransferredData
        }

        // Prevent:
        // * Users with an unknown GRDB schema revert to using an earlier GRDB schema.
        guard !StorageCoordinator.hasInvalidDatabaseVersion else {
            return .unknownDatabaseVersion
        }

        let userDefaults = mainAppContext.appUserDefaults()

        let databaseCorruptionState = DatabaseCorruptionState(userDefaults: userDefaults)
        switch databaseCorruptionState.status {
        case .notCorrupted:
            break
        case .corrupted, .corruptedButAlreadyDumpedAndRestored:
            guard !UIDevice.current.isIPad else {
                // Database recovery theoretically works on iPad,
                // but we haven't built the UI for it.
                return .databaseUnrecoverablyCorrupted
            }
            guard databaseCorruptionState.count <= 3 else {
                return .databaseUnrecoverablyCorrupted
            }
            return .databaseCorruptedAndMightBeRecoverable
        }

        let launchAttemptFailureThreshold = DebugFlags.betaLogging ? 2 : 3
        if
            appVersion.lastAppVersion == appVersion.currentAppReleaseVersion,
            userDefaults.integer(forKey: kAppLaunchesAttemptedKey) >= launchAttemptFailureThreshold
        {
            return .lastAppLaunchCrashed
        }

        return nil
    }

    private func showPreflightErrorUI(
        _ preflightError: LaunchPreflightError,
        window: UIWindow,
        viewController: UIViewController,
        launchStartedAt: CFTimeInterval
    ) {
        Logger.warn("preflightError: \(preflightError)")

        // Disable normal functioning of app.
        didAppLaunchFail = true

        let title: String
        let message: String
        let actions: [LaunchFailureActionSheetAction]

        switch preflightError {
        case .databaseCorruptedAndMightBeRecoverable:
            presentDatabaseRecovery(from: viewController, window: window, launchStartedAt: launchStartedAt)
            return

        case .databaseUnrecoverablyCorrupted:
            title = NSLocalizedString(
                "APP_LAUNCH_FAILURE_COULD_NOT_LOAD_DATABASE",
                comment: "Error indicating that the app could not launch because the database could not be loaded."
            )
            message = NSLocalizedString(
                "APP_LAUNCH_FAILURE_ALERT_MESSAGE",
                comment: "Default message for the 'app launch failed' alert."
            )
            actions = [.submitDebugLogsWithDatabaseIntegrityCheckAndCrash]

        case .unknownDatabaseVersion:
            title = NSLocalizedString(
                "APP_LAUNCH_FAILURE_INVALID_DATABASE_VERSION_TITLE",
                comment: "Error indicating that the app could not launch without reverting unknown database migrations."
            )
            message = NSLocalizedString(
                "APP_LAUNCH_FAILURE_INVALID_DATABASE_VERSION_MESSAGE",
                comment: "Error indicating that the app could not launch without reverting unknown database migrations."
            )
            actions = [.submitDebugLogsAndCrash]

        case .couldNotRestoreTransferredData:
            title = NSLocalizedString(
                "APP_LAUNCH_FAILURE_RESTORE_FAILED_TITLE",
                comment: "Error indicating that the app could not restore transferred data."
            )
            message = NSLocalizedString(
                "APP_LAUNCH_FAILURE_RESTORE_FAILED_MESSAGE",
                comment: "Error indicating that the app could not restore transferred data."
            )
            actions = [.submitDebugLogsAndCrash]

        case .lastAppLaunchCrashed:
            title = NSLocalizedString(
                "APP_LAUNCH_FAILURE_LAST_LAUNCH_CRASHED_TITLE",
                comment: "Error indicating that the app crashed during the previous launch."
            )
            message = NSLocalizedString(
                "APP_LAUNCH_FAILURE_LAST_LAUNCH_CRASHED_MESSAGE",
                comment: "Error indicating that the app crashed during the previous launch."
            )
            actions = [.submitDebugLogsAndLaunchApp(window: window), .launchApp(window: window)]

        case .lowStorageSpaceAvailable:
            shouldKillAppWhenBackgrounded = true
            title = NSLocalizedString(
                "APP_LAUNCH_FAILURE_LOW_STORAGE_SPACE_AVAILABLE_TITLE",
                comment: "Error title indicating that the app crashed because there was low storage space available on the device."
            )
            message = NSLocalizedString(
                "APP_LAUNCH_FAILURE_LOW_STORAGE_SPACE_AVAILABLE_MESSAGE",
                comment: "Error description indicating that the app crashed because there was low storage space available on the device."
            )
            actions = []
        }

        presentLaunchFailureActionSheet(
            from: viewController,
            launchStartedAt: launchStartedAt,
            supportTag: preflightError.supportTag,
            title: title,
            message: message,
            actions: actions
        )
    }

    private func presentDatabaseRecovery(
        from viewController: UIViewController,
        window: UIWindow,
        launchStartedAt: CFTimeInterval
    ) {
        let recoveryViewController = DatabaseRecoveryViewController<(AppSetup.FinalContinuation, NSObject)>(
            setupSskEnvironment: {
                firstly(on: DispatchQueue.main) {
                    self.setUpMainAppEnvironment()
                }
            },
            launchApp: { (finalContinuation, sleepBlockObject) in
                // Pretend we didn't fail!
                self.didAppLaunchFail = false
                self.configureGlobalUI(in: window)
                self.didLoadDatabase(
                    finalContinuation: finalContinuation,
                    sleepBlockObject: sleepBlockObject,
                    window: window,
                    launchStartedAt: launchStartedAt
                )
            }
        )

        // Prevent dismissal.
        if #available(iOS 13, *) {
            recoveryViewController.isModalInPresentation = true
        } else {
            // This presents it fullscreen. Not ideal, but only affects old iOS versions, and prevents dismissal.
            recoveryViewController.modalPresentationStyle = .fullScreen
        }

        // Show as a half-sheet on iOS 15+. On older versions, the sheet fills the screen, which is okay.
        if #available(iOS 15, *), let presentationController = recoveryViewController.presentationController as? UISheetPresentationController {
            presentationController.detents = [.medium()]
            presentationController.prefersEdgeAttachedInCompactHeight = true
            presentationController.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }

        viewController.present(recoveryViewController, animated: true)
    }

    private enum LaunchFailureActionSheetAction {
        case submitDebugLogsAndCrash
        case submitDebugLogsAndLaunchApp(window: UIWindow)
        case submitDebugLogsWithDatabaseIntegrityCheckAndCrash
        case launchApp(window: UIWindow)
    }

    private func presentLaunchFailureActionSheet(
        from viewController: UIViewController,
        launchStartedAt: CFTimeInterval,
        supportTag: String,
        title: String,
        message: String,
        actions: [LaunchFailureActionSheetAction]
    ) {
        let actionSheet = ActionSheetController(title: title, message: message)

        if DebugFlags.internalSettings {
            actionSheet.addAction(.init(title: "Export Database (internal)") { [unowned viewController] _ in
                SignalApp.showExportDatabaseUI(from: viewController) {
                    self.presentLaunchFailureActionSheet(
                        from: viewController,
                        launchStartedAt: launchStartedAt,
                        supportTag: supportTag,
                        title: title,
                        message: message,
                        actions: actions
                    )
                }
            })
        }

        func addSubmitDebugLogsAction(handler: @escaping () -> Void) {
            let actionTitle = NSLocalizedString("SETTINGS_ADVANCED_SUBMIT_DEBUGLOG", comment: "")
            actionSheet.addAction(.init(title: actionTitle) { _ in
                handler()
            })
        }

        func ignoreErrorAndLaunchApp(in window: UIWindow) {
            // Pretend we didn't fail!
            self.didAppLaunchFail = false
            window.rootViewController = LoadingViewController()
            self.launchApp(in: window, launchStartedAt: launchStartedAt)
        }

        for action in actions {
            switch action {
            case .submitDebugLogsAndCrash:
                addSubmitDebugLogsAction {
                    DebugLogs.submitLogs(withSupportTag: supportTag) {
                        owsFail("Exiting after submitting debug logs")
                    }
                }
            case .submitDebugLogsAndLaunchApp(let window):
                addSubmitDebugLogsAction { [unowned window] in
                    DebugLogs.submitLogs(withSupportTag: supportTag) {
                        ignoreErrorAndLaunchApp(in: window)
                    }
                }
            case .submitDebugLogsWithDatabaseIntegrityCheckAndCrash:
                addSubmitDebugLogsAction { [unowned viewController] in
                    SignalApp.showDatabaseIntegrityCheckUI(from: viewController) {
                        DebugLogs.submitLogs(withSupportTag: supportTag) {
                            owsFail("Exiting after submitting debug logs")
                        }
                    }
                }
            case .launchApp(let window):
                actionSheet.addAction(.init(
                    title: NSLocalizedString(
                        "APP_LAUNCH_FAILURE_CONTINUE",
                        comment: "Button to try launching the app even though the last launch failed"
                    ),
                    style: .cancel, // Use a cancel-style button to draw attention.
                    handler: { [unowned window] _ in
                        ignoreErrorAndLaunchApp(in: window)
                    }
                ))
            }
        }

        viewController.presentActionSheet(actionSheet)
    }

    private func terminalErrorViewController() -> UIViewController {
        let storyboard = UIStoryboard(name: "Launch Screen", bundle: nil)
        guard let viewController = storyboard.instantiateInitialViewController() else {
            owsFail("No initial view controller")
        }
        return viewController
    }

    // MARK: - Remote notifications

    enum HandleSilentPushContentResult: UInt {
        case handled
        case notHandled
    }

    @objc
    func processRemoteNotification(_ remoteNotification: NSDictionary, completion: @escaping () -> Void) {
        AssertIsOnMainThread()

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            guard self.tsAccountManager.isRegisteredAndReady else {
                Logger.info("Ignoring remote notification; user is not registered.")
                return
            }

            // TODO: NSE Lifecycle, is this invoked when the NSE wakes the main app?
            if
                let remoteNotification = remoteNotification as? [AnyHashable: Any],
                self.handleSilentPushContent(remoteNotification) == .notHandled {
                self.messageFetcherJob.run()

                // If the main app gets woken to process messages in the background, check
                // for any pending NSE requests to fulfill.
                self.syncManager.syncAllContactsIfFullSyncRequested()
            }

            completion()
        }
    }

    func handleSilentPushContent(_ remoteNotification: [AnyHashable: Any]) -> HandleSilentPushContentResult {
        if let spamChallengeToken = remoteNotification["rateLimitChallenge"] as? String {
            spamChallengeResolver.handleIncomingPushChallengeToken(spamChallengeToken)
            return .handled
        }

        if let preAuthChallengeToken = remoteNotification["challenge"] as? String {
            pushRegistrationManager.didReceiveVanillaPreAuthChallengeToken(preAuthChallengeToken)
            return .handled
        }

        return .notHandled
    }

    // MARK: - Events

    @objc
    private func registrationStateDidChange() {
        AssertIsOnMainThread()

        Logger.info("registrationStateDidChange")

        enableBackgroundRefreshIfNecessary()

        let isRegisteredAndReady = tsAccountManager.isRegisteredAndReady
        if isRegisteredAndReady {
            AppReadiness.runNowOrWhenAppDidBecomeReadySync {
                self.databaseStorage.write { transaction in
                    let localAddress = self.tsAccountManager.localAddress(with: transaction)
                    Logger.info("localAddress: \(String(describing: localAddress))")

                    ExperienceUpgradeFinder.markAllCompleteForNewUser(transaction: transaction.unwrapGrdbWrite)
                }

                // Start running the disappearing messages job in case the newly registered user
                // enables this feature
                self.disappearingMessagesJob.startIfNecessary()
            }
        }

        Self.updateApplicationShortcutItems(isRegisteredAndReady: isRegisteredAndReady)
    }

    @objc
    private func registrationLockDidChange() {
        enableBackgroundRefreshIfNecessary()
    }

    // MARK: - Utilities

    @objc
    public static func updateApplicationShortcutItems(isRegisteredAndReady: Bool) {
        guard CurrentAppContext().isMainApp else { return }
        UIApplication.shared.shortcutItems = applicationShortcutItems(isRegisteredAndReady: isRegisteredAndReady)
    }

    static func applicationShortcutItems(isRegisteredAndReady: Bool) -> [UIApplicationShortcutItem] {
        guard isRegisteredAndReady else { return [] }
        return [.init(
            type: "\(Bundle.main.bundleIdPrefix).quickCompose",
            localizedTitle: NSLocalizedString(
                "APPLICATION_SHORTCUT_NEW_MESSAGE",
                comment: "On the iOS home screen, if you tap and hold the Signal icon, this shortcut will appear. Tapping it will let users send a new message. You may want to refer to similar behavior in other iOS apps, such as Messages, for equivalent strings."
            ),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(type: .compose)
        )]
    }

    // MARK: - URL Handling

    @objc
    func handleOpenUrl(_ url: URL) -> Bool {
        AssertIsOnMainThread()

        if self.didAppLaunchFail {
            Logger.error("App launch failed")
            return false
        }

        guard let parsedUrl = UrlOpener.parseUrl(url) else {
            return false
        }
        AppReadiness.runNowOrWhenUIDidBecomeReadySync {
            let urlOpener = UrlOpener(tsAccountManager: self.tsAccountManager)
            urlOpener.openUrl(parsedUrl, in: self.window!)
        }
        return true
    }

    // MARK: - Database integrity checks

    private func checkDatabaseIntegrityIfNecessary(
        isRegistered: Bool
    ) {
        guard isRegistered, FeatureFlags.periodicallyCheckDatabaseIntegrity else { return }

        DispatchQueue.sharedBackground.async {
            switch GRDBDatabaseStorageAdapter.checkIntegrity() {
            case .ok: break
            case .notOk:
                AppReadiness.runNowOrWhenUIDidBecomeReadySync {
                    OWSActionSheets.showActionSheet(
                        title: "Database corrupted!",
                        message: "We have detected database corruption on your device. Please submit debug logs to the iOS team."
                    )
                }
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    // The method will be called on the delegate only if the application is in the foreground. If the method is not
    // implemented or the handler is not called in a timely manner then the notification will not be presented. The
    // application can choose to have the notification presented as a sound, badge, alert and/or in the notification list.
    // This decision should be based on whether the information in the notification is otherwise visible to the user.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Logger.info("")

        // Capture just userInfo; we don't want to retain notification.
        let remoteNotification = notification.request.content.userInfo
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            let options: UNNotificationPresentationOptions
            switch self.handleSilentPushContent(remoteNotification) {
            case .handled:
                options = []
            case .notHandled:
                // We need to respect the in-app notification sound preference. This method, which is called
                // for modern UNUserNotification users, could be a place to do that, but since we'd still
                // need to handle this behavior for legacy UINotification users anyway, we "allow" all
                // notification options here, and rely on the shared logic in NotificationPresenter to
                // honor notification sound preferences for both modern and legacy users.
                options = [.alert, .badge, .sound]
            }
            completionHandler(options)
        }
    }

    // The method will be called on the delegate when the user responded to the notification by opening the application,
    // dismissing the notification or choosing a UNNotificationAction. The delegate must be set before the application
    // returns from application:didFinishLaunchingWithOptions:.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Logger.info("")
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            NotificationActionHandler.handleNotificationResponse(response, completionHandler: completionHandler)
        }
    }
}
