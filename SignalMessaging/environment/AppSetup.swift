//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit
import SignalServiceKit

public class AppSetup {
    public init() {}

    public func start(
        appContext: AppContext,
        paymentsEvents: PaymentsEvents,
        mobileCoinHelper: MobileCoinHelper,
        webSocketFactory: WebSocketFactory,
        callMessageHandler: OWSCallMessageHandler,
        notificationPresenter: NotificationsProtocol
    ) -> AppSetup.DatabaseContinuation {
        configureUnsatisfiableConstraintLogging()

        let sleepBlockObject = NSObject()
        DeviceSleepManager.shared.addBlock(blockObject: sleepBlockObject)

        let backgroundTask = OWSBackgroundTask(label: #function)

        // Order matters here.
        //
        // All of these "singletons" should have any dependencies used in their
        // initializers injected.
        OWSBackgroundTaskManager.shared().observeNotifications()

        let storageCoordinator = StorageCoordinator()
        Logger.info("hasGrdbFile: \(StorageCoordinator.hasGrdbFile)")
        let databaseStorage = storageCoordinator.nonGlobalDatabaseStorage

        // AFNetworking (via CFNetworking) spools its attachments in
        // NSTemporaryDirectory(). If you receive a media message while the device
        // is locked, the download will fail if the temporary directory is
        // NSFileProtectionComplete.
        let temporaryDirectory = NSTemporaryDirectory()
        owsAssert(OWSFileSystem.ensureDirectoryExists(temporaryDirectory))
        owsAssert(OWSFileSystem.protectFileOrFolder(atPath: temporaryDirectory, fileProtectionType: .completeUntilFirstUserAuthentication))

        // MARK: DependenciesBridge

        let accountServiceClient = AccountServiceClient()
        let identityManager = OWSIdentityManager(databaseStorage: databaseStorage)
        let messageProcessor = MessageProcessor()
        let messageSender = MessageSender()
        let networkManager = NetworkManager()
        let ows2FAManager = OWS2FAManager()
        let pniSignalProtocolStore = SignalProtocolStore(for: .pni)
        let signalService = OWSSignalService()
        let storageServiceManager = StorageServiceManagerImpl.shared
        let syncManager = OWSSyncManager(default: ())
        let tsAccountManager = TSAccountManager()

        DependenciesBridge.setupSingleton(
            accountServiceClient: accountServiceClient,
            databaseStorage: databaseStorage,
            identityManager: identityManager,
            messageProcessor: messageProcessor,
            messageSender: messageSender,
            networkManager: networkManager,
            ows2FAManager: ows2FAManager,
            pniProtocolStore: pniSignalProtocolStore,
            signalService: signalService,
            storageServiceManager: storageServiceManager,
            syncManager: syncManager,
            tsAccountManager: tsAccountManager
        )

        // MARK: SignalMessaging environment properties

        let preferences = OWSPreferences()
        let proximityMonitoringManager = OWSProximityMonitoringManagerImpl()
        let sounds = OWSSounds()
        let orphanDataCleaner = OWSOrphanDataCleaner()
        let avatarBuilder = AvatarBuilder()
        let smJobQueues = SignalMessagingJobQueues()

        // MARK: SSK environment properties

        let contactsManager = OWSContactsManager(swiftValues: .makeWithValuesFromDependenciesBridge())
        let linkPreviewManager = OWSLinkPreviewManager()
        let pendingReceiptRecorder = MessageRequestPendingReceipts()
        let profileManager = OWSProfileManager(databaseStorage: databaseStorage)
        let messageManager = OWSMessageManager()
        let blockingManager = BlockingManager()
        let remoteConfigManager = ServiceRemoteConfigManager()
        let aciSignalProtocolStore = SignalProtocolStore(for: .aci)
        let udManager = OWSUDManagerImpl()
        let messageDecrypter = OWSMessageDecrypter()
        let groupsV2MessageProcessor = GroupsV2MessageProcessor()
        let socketManager = SocketManager()
        let disappearingMessagesJob = OWSDisappearingMessagesJob()
        let receiptManager = OWSReceiptManager()
        let outgoingReceiptManager = OWSOutgoingReceiptManager()
        let reachabilityManager = SSKReachabilityManagerImpl()
        let typingIndicators = TypingIndicatorsImpl()
        let attachmentDownloads = OWSAttachmentDownloads()
        let stickerManager = StickerManager()
        let signalServiceAddressCache = SignalServiceAddressCache()
        let sskPreferences = SSKPreferences()
        let groupsV2 = GroupsV2Impl()
        let groupV2Updates = GroupV2UpdatesImpl()
        let messageFetcherJob = MessageFetcherJob()
        let bulkProfileFetch = BulkProfileFetch()
        let versionedProfiles = VersionedProfilesImpl()
        let modelReadCaches = ModelReadCaches(factory: ModelReadCacheFactory())
        let earlyMessageManager = EarlyMessageManager()
        let messagePipelineSupervisor = MessagePipelineSupervisor.createStandardSupervisor()
        let appExpiry = AppExpiry(
            keyValueStoreFactory: SDSKeyValueStoreFactory(),
            dateProvider: Date.provider,
            schedulers: DispatchQueueSchedulers()
        )
        let paymentsHelper = PaymentsHelperImpl()
        let paymentsCurrencies = PaymentsCurrenciesImpl()
        let spamChallengeResolver = SpamChallengeResolver()
        let senderKeyStore = SenderKeyStore()
        let phoneNumberUtil = PhoneNumberUtil()
        let legacyChangePhoneNumber = LegacyChangePhoneNumber()
        let subscriptionManager = SubscriptionManagerImpl()
        let systemStoryManager = SystemStoryManager()
        let remoteMegaphoneFetcher = RemoteMegaphoneFetcher()
        let sskJobQueues = SSKJobQueues()
        let contactDiscoveryManager = ContactDiscoveryManagerImpl()

        Environment.shared = Environment(
            preferences: preferences,
            proximityMonitoringManager: proximityMonitoringManager,
            sounds: sounds,
            orphanDataCleaner: orphanDataCleaner,
            avatarBuilder: avatarBuilder,
            smJobQueues: smJobQueues
        )

        let sskEnvironment = SSKEnvironment(
            contactsManager: contactsManager,
            linkPreviewManager: linkPreviewManager,
            messageSender: messageSender,
            pendingReceiptRecorder: pendingReceiptRecorder,
            profileManager: profileManager,
            networkManager: networkManager,
            messageManager: messageManager,
            blockingManager: blockingManager,
            identityManager: identityManager,
            remoteConfigManager: remoteConfigManager,
            aciSignalProtocolStore: aciSignalProtocolStore,
            pniSignalProtocolStore: pniSignalProtocolStore,
            udManager: udManager,
            messageDecrypter: messageDecrypter,
            groupsV2MessageProcessor: groupsV2MessageProcessor,
            socketManager: socketManager,
            tsAccountManager: tsAccountManager,
            ows2FAManager: ows2FAManager,
            disappearingMessagesJob: disappearingMessagesJob,
            receiptManager: receiptManager,
            outgoingReceiptManager: outgoingReceiptManager,
            reachabilityManager: reachabilityManager,
            syncManager: syncManager,
            typingIndicators: typingIndicators,
            attachmentDownloads: attachmentDownloads,
            stickerManager: stickerManager,
            databaseStorage: databaseStorage,
            signalServiceAddressCache: signalServiceAddressCache,
            signalService: signalService,
            accountServiceClient: accountServiceClient,
            storageServiceManager: storageServiceManager,
            storageCoordinator: storageCoordinator,
            sskPreferences: sskPreferences,
            groupsV2: groupsV2,
            groupV2Updates: groupV2Updates,
            messageFetcherJob: messageFetcherJob,
            bulkProfileFetch: bulkProfileFetch,
            versionedProfiles: versionedProfiles,
            modelReadCaches: modelReadCaches,
            earlyMessageManager: earlyMessageManager,
            messagePipelineSupervisor: messagePipelineSupervisor,
            appExpiry: appExpiry,
            messageProcessor: messageProcessor,
            paymentsHelper: paymentsHelper,
            paymentsCurrencies: paymentsCurrencies,
            paymentsEvents: paymentsEvents,
            mobileCoinHelper: mobileCoinHelper,
            spamChallengeResolver: spamChallengeResolver,
            senderKeyStore: senderKeyStore,
            phoneNumberUtil: phoneNumberUtil,
            webSocketFactory: webSocketFactory,
            legacyChangePhoneNumber: legacyChangePhoneNumber,
            subscriptionManager: subscriptionManager,
            systemStoryManager: systemStoryManager,
            remoteMegaphoneFetcher: remoteMegaphoneFetcher,
            sskJobQueues: sskJobQueues,
            contactDiscoveryManager: contactDiscoveryManager,
            callMessageHandler: callMessageHandler,
            notificationsManager: notificationPresenter
        )
        SSKEnvironment.setShared(sskEnvironment, isRunningTests: appContext.isRunningTests)

        // Register renamed classes.
        NSKeyedUnarchiver.setClass(OWSUserProfile.self, forClassName: OWSUserProfile.collection())
        NSKeyedUnarchiver.setClass(OWSGroupInfoRequestMessage.self, forClassName: "OWSSyncGroupsRequestMessage")
        NSKeyedUnarchiver.setClass(TSGroupModelV2.self, forClassName: "TSGroupModelV2")

        return AppSetup.DatabaseContinuation(
            appContext: appContext,
            sskEnvironment: sskEnvironment,
            backgroundTask: backgroundTask
        )
    }

    private func configureUnsatisfiableConstraintLogging() {
        UserDefaults.standard.setValue(DebugFlags.internalLogging, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
    }
}

// MARK: - DatabaseContinuation

extension AppSetup {
    public class DatabaseContinuation {
        private let appContext: AppContext
        private let sskEnvironment: SSKEnvironment
        private let backgroundTask: OWSBackgroundTask

        fileprivate init(
            appContext: AppContext,
            sskEnvironment: SSKEnvironment,
            backgroundTask: OWSBackgroundTask
        ) {
            self.appContext = appContext
            self.sskEnvironment = sskEnvironment
            self.backgroundTask = backgroundTask
        }
    }
}

extension AppSetup.DatabaseContinuation {
    public func prepareDatabase() -> Guarantee<AppSetup.FinalContinuation> {
        let databaseStorage = sskEnvironment.databaseStorageRef

        let (guarantee, future) = Guarantee<AppSetup.FinalContinuation>.pending()
        DispatchQueue.global().async {
            if self.shouldTruncateGrdbWal() {
                // Try to truncate GRDB WAL before any readers or writers are active.
                do {
                    try databaseStorage.grdbStorage.syncTruncatingCheckpoint()
                } catch {
                    owsFailDebug("Failed to truncate database: \(error)")
                }
            }
            databaseStorage.runGrdbSchemaMigrationsOnMainDatabase {
                self.sskEnvironment.warmCaches()
                self.backgroundTask.end()
                future.resolve(AppSetup.FinalContinuation(sskEnvironment: self.sskEnvironment))
            }
        }
        return guarantee
    }

    private func shouldTruncateGrdbWal() -> Bool {
        guard appContext.isMainApp else {
            return false
        }
        guard appContext.mainApplicationStateOnLaunch() != .background else {
            return false
        }
        return true
    }
}

// MARK: - FinalContinuation

extension AppSetup {
    public class FinalContinuation {
        private let sskEnvironment: SSKEnvironment

        fileprivate init(sskEnvironment: SSKEnvironment) {
            self.sskEnvironment = sskEnvironment
        }
    }
}

extension AppSetup.FinalContinuation {
    public enum SetupError: Error {
        case corruptRegistrationState
    }

    public func finish(willResumeInProgressRegistration: Bool) -> SetupError? {
        AssertIsOnMainThread()

        guard setUpLocalIdentifiers(willResumeInProgressRegistration: willResumeInProgressRegistration) else {
            return .corruptRegistrationState
        }

        // Do this after we've finished running database migrations.
        if DebugFlags.internalLogging {
            DispatchQueue.global().async { SDSKeyValueStore.logCollectionStatistics() }
        }

        return nil
    }

    private func setUpLocalIdentifiers(willResumeInProgressRegistration: Bool) -> Bool {
        let databaseStorage = sskEnvironment.databaseStorageRef
        let storageServiceManager = sskEnvironment.storageServiceManagerRef
        let tsAccountManager = sskEnvironment.tsAccountManagerRef

        let updateLocalIdentifiers: (LocalIdentifiersObjC) -> Void = { [weak storageServiceManager] localIdentifiers in
            storageServiceManager?.setLocalIdentifiers(localIdentifiers)
        }

        // If we're not registered, listen for when we become registered. If we are
        // registered, listen for when we learn about our PNI or change our number.
        tsAccountManager.didStoreLocalNumber = updateLocalIdentifiers

        if tsAccountManager.isOnboarded && !willResumeInProgressRegistration {
            let localIdentifiers = databaseStorage.read { tsAccountManager.localIdentifiers(transaction: $0) }
            guard let localIdentifiers else {
                return false
            }
            updateLocalIdentifiers(LocalIdentifiersObjC(localIdentifiers))
        }

        return true
    }
}
