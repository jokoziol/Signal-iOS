//
// Copyright 2016 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalMessaging
import SignalServiceKit

public enum AccountManagerError: Error {
    case reregistrationDifferentAccount
}

// MARK: -

/**
 * Signal is actually two services - textSecure for messages and red phone (for calls). 
 * AccountManager delegates to both.
 */
@objc
public class AccountManager: NSObject, Dependencies {

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            if self.tsAccountManager.isRegistered {
                self.recordUuidIfNecessary()
            }
        }
    }

    // MARK: registration

    func deprecated_requestRegistrationVerification(e164: String, captchaToken: String?, isSMS: Bool) -> Promise<Void> {
        deprecated_requestAccountVerification(e164: e164,
                                   captchaToken: captchaToken,
                                   isSMS: isSMS,
                                   mode: .registration)
    }

    public enum VerificationMode {
        case registration
        case changePhoneNumber
    }

    public func deprecated_requestAccountVerification(e164: String,
                                                      captchaToken: String?,
                                                      isSMS: Bool,
                                                      mode: VerificationMode) -> Promise<Void> {
        let transport: TSVerificationTransport = isSMS ? .SMS : .voice

        return firstly { () -> Promise<String?> in
            switch mode {
            case .registration:
                guard !self.tsAccountManager.isRegistered else {
                    throw OWSAssertionError("requesting account verification when already registered")
                }

                self.tsAccountManager.phoneNumberAwaitingVerification = e164

            case .changePhoneNumber:
                // Don't set phoneNumberAwaitingVerification in the "change phone number" flow.
                break
            }

            return self.deprecated_getPreauthChallenge(e164: e164)
        }.then { (preauthChallenge: String?) -> Promise<Void> in
            self.accountServiceClient.deprecated_requestVerificationCode(e164: e164,
                                                                         preauthChallenge: preauthChallenge,
                                                                         captchaToken: captchaToken,
                                                                         transport: transport)
        }
    }

    func deprecated_getPreauthChallenge(e164: String) -> Promise<String?> {
        return firstly {
            return self.pushRegistrationManager.requestPushTokens(forceRotation: false)
        }.then { (vanillaToken: String, voipToken: String?) -> Promise<String?> in
            self.pushRegistrationManager.clearPreAuthChallengeToken()
            let pushPromise = self.pushRegistrationManager.receivePreAuthChallengeToken()

            return self.accountServiceClient.deprecated_requestPreauthChallenge(
                e164: e164,
                pushToken: voipToken?.nilIfEmpty ?? vanillaToken,
                isVoipToken: !voipToken.isEmptyOrNil
            ).then { () -> Promise<String?> in
                let timeout: TimeInterval
                if OWSIsDebugBuild() && TSConstants.isUsingProductionService {
                    // won't receive production voip in debug build, don't wait for long
                    timeout = 0.5
                } else {
                    timeout = 5
                }

                return pushPromise.nilTimeout(seconds: timeout)
            }
        }.recover { (error: Error) -> Promise<String?> in
            switch error {
            case PushRegistrationError.pushNotSupported(description: let description):
                Logger.warn("Push not supported: \(description)")
            case is OWSHTTPError:
                // not deployed to production yet.
                if error.httpStatusCode == 404 {
                    Logger.warn("404 while requesting preauthChallenge: \(error)")
                } else if error.isNetworkFailureOrTimeout {
                    Logger.warn("Network failure while requesting preauthChallenge: \(error)")
                } else {
                    fallthrough
                }
            default:
                owsFailDebug("error while requesting preauthChallenge: \(error)")
            }
            return Promise.value(nil)
        }
    }

    func register(verificationCode: String, pin: String?, checkForAvailableTransfer: Bool) -> Promise<Void> {
        if verificationCode.isEmpty {
            let error = OWSError(error: .userError,
                                 description: NSLocalizedString("REGISTRATION_ERROR_BLANK_VERIFICATION_CODE",
                                                                comment: "alert body during registration"),
                                 isRetryable: false)
            return Promise(error: error)
        }

        Logger.debug("registering with signal server")

        return firstly {
            self.registerForTextSecure(verificationCode: verificationCode, pin: pin, checkForAvailableTransfer: checkForAvailableTransfer)
        }.then { response -> Promise<Void> in
            self.tsAccountManager.uuidAwaitingVerification = response.aci
            self.tsAccountManager.pniAwaitingVerification = response.pni

            self.databaseStorage.write { transaction in
                if !self.tsAccountManager.isReregistering {
                    // For new users, read receipts are on by default.
                    self.receiptManager.setAreReadReceiptsEnabled(true,
                                                                  transaction: transaction)
                    StoryManager.setAreViewReceiptsEnabled(true, transaction: transaction)

                    // New users also have the onboarding banner cards enabled
                    GetStartedBannerViewController.enableAllCards(writeTx: transaction)
                }

                // If the user previously had a PIN, but we don't have record of it,
                // mark them as pending restoration during onboarding. Reg lock users
                // will have already restored their PIN by this point.
                if response.hasPreviouslyUsedKBS, !DependenciesBridge.shared.keyBackupService.hasMasterKey {
                    DependenciesBridge.shared.keyBackupService.recordPendingRestoration(transaction: transaction.asV2Write)
                }
            }

            return self.accountServiceClient.updatePrimaryDeviceAccountAttributes()
        }.then {
            self.createPreKeys()
        }.done {
            self.profileManager.fetchLocalUsersProfile(authedAccount: .implicit())
        }.then { _ -> Promise<Void> in
            return self.syncPushTokens().recover { (error) -> Promise<Void> in
                switch error {
                case PushRegistrationError.pushNotSupported(let description):
                    // This can happen with:
                    // - simulators, none of which support receiving push notifications
                    // - on iOS11 devices which have disabled "Allow Notifications" and disabled "Enable Background Refresh" in the system settings.
                    Logger.info("Recovered push registration error. Registering for manual message fetcher because push not supported: \(description)")
                    self.tsAccountManager.setIsManualMessageFetchEnabled(true)
                    return self.accountServiceClient.updatePrimaryDeviceAccountAttributes()
                default:
                    throw error
                }
            }
        }.done {
            self.completeRegistration()
        }.then { _ -> Promise<Void> in
            self.performInitialStorageServiceRestore()
        }
    }

    func deprecated_requestChangePhoneNumber(
        newPhoneNumber: String,
        verificationCode: String,
        registrationLock: String?
    ) -> Promise<Void> {
        guard let verificationCode = verificationCode.nilIfEmpty else {
            let error = OWSError(
                error: .userError,
                description: OWSLocalizedString(
                    "REGISTRATION_ERROR_BLANK_VERIFICATION_CODE",
                    comment: "alert body during registration"
                ),
                isRetryable: false
            )

            return Promise(error: error)
        }

        guard let newE164 = E164(newPhoneNumber) else {
            return Promise(error: OWSAssertionError("Invalid new phone number!"))
        }

        Logger.info("Changing phone number.")

        typealias PniParameters = ChangePhoneNumberPni.Parameters
        typealias ChangeToken = LegacyChangePhoneNumber.ChangeToken

        return firstly { () -> Promise<(PniParameters, ChangeToken)> in
            // Mark a change as in flight.  If the change is interrupted, we'll
            // check on next app launch to ensure local client state reflects
            // current service state.

            databaseStorage.write { transaction -> Promise<(PniParameters, ChangeToken)> in
                legacyChangePhoneNumber.deprecated_buildNewChangeToken(
                    forNewE164: newE164,
                    transaction: transaction
                )
            }
        }.then(on: DispatchQueue.global()) { (parameters, changeToken) -> Promise<Void> in
            firstly { () -> Promise<ChangePhoneNumberResponse> in
                // Make the request to change phone number and PNI parameters on
                // the service.

                self.makeChangePhoneNumberRequest(
                    newE164: newE164,
                    verificationCode: verificationCode,
                    registrationLock: registrationLock,
                    pniChangePhoneNumberParameters: parameters
                )
            }.map(on: DispatchQueue.global()) { changePhoneNumberResponse -> Void in
                // Update local state to match new service state.

                self.databaseStorage.write { transaction in
                    self.legacyChangePhoneNumber.changeDidComplete(
                        changeToken: changeToken,
                        successfulChangeParams: LegacyChangePhoneNumber.SuccessfulChangeParams(
                            newServiceE164: changePhoneNumberResponse.e164,
                            serviceAci: changePhoneNumberResponse.aci,
                            servicePni: changePhoneNumberResponse.pni
                        ),
                        transaction: transaction
                    )
                }

                self.profileManager.fetchLocalUsersProfile(authedAccount: .implicit())
            }
        }
    }

    private struct ChangePhoneNumberResponse: Decodable {
        private enum CodingKeys: String, CodingKey {
            case aci = "uuid"
            case pni
            case e164 = "number"
        }

        let aci: UUID
        let pni: UUID
        let e164: E164
    }

    private func makeChangePhoneNumberRequest(
        newE164: E164,
        verificationCode: String,
        registrationLock: String?,
        pniChangePhoneNumberParameters: ChangePhoneNumberPni.Parameters
    ) -> Promise<ChangePhoneNumberResponse> {
        firstly { () -> Promise<HTTPResponse> in
            let request = OWSRequestFactory.changePhoneNumberRequest(
                newPhoneNumberE164: newE164.stringValue,
                verificationCode: verificationCode,
                registrationLock: registrationLock,
                pniChangePhoneNumberParameters: pniChangePhoneNumberParameters
            )

            return networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response -> ChangePhoneNumberResponse in
            let statusCode = response.responseStatusCode

            switch statusCode {
            case 200, 204:
                guard let data = response.responseBodyData else {
                    throw OWSAssertionError("Missing or invalid body data!")
                }

                Logger.info("Change-number request accepted!")

                return try JSONDecoder().decode(ChangePhoneNumberResponse.self, from: data)
            default:
                throw OWSAssertionError("Unexpected status while verifying code: \(statusCode)")
            }
        }.recover(on: DispatchQueue.global()) { error throws -> Promise<ChangePhoneNumberResponse> in
            throw TSAccountManager.processRegistrationError(error)
        }
    }

    func performInitialStorageServiceRestore(authedAccount: AuthedAccount = .implicit()) -> Promise<Void> {
        BenchEventStart(title: "waiting for initial storage service restore", eventId: "initial-storage-service-restore")
        return firstly {
            self.storageServiceManager.restoreOrCreateManifestIfNecessary(authedAccount: authedAccount).asVoid()
        }.done {
            // In the case that we restored our profile from a previous registration,
            // re-upload it so that the user does not need to refill in all the details.
            // Right now the avatar will always be lost since we do not store avatars in
            // the storage service.

            if self.profileManager.hasProfileName || self.profileManager.localProfileAvatarData() != nil {
                Logger.debug("restored local profile name. Uploading...")
                // if we don't have a `localGivenName`, there's nothing to upload, and trying
                // to upload would fail.

                // Note we *don't* return this promise. There's no need to block registration on
                // it completing, and if there are any errors, it's durable.
                firstly {
                    self.profileManagerImpl.reuploadLocalProfilePromise(authedAccount: authedAccount)
                }.catch { error in
                    Logger.error("error: \(error)")
                }
            } else {
                Logger.debug("no local profile name restored.")
            }

            BenchEventComplete(eventId: "initial-storage-service-restore")
        }.timeout(seconds: 60)
    }

    func completeSecondaryLinking(provisionMessage: ProvisionMessage, deviceName: String) -> Promise<Void> {
        // * Primary devices _can_ re-register with a new uuid.
        // * Secondary devices _cannot_ be re-linked to primaries with a different uuid.
        if tsAccountManager.isReregistering {
            var canChangePhoneNumbers = false
            if let oldUUID = tsAccountManager.reregistrationUUID(),
               let newUUID = provisionMessage.aci {
                if !tsAccountManager.isPrimaryDevice,
                   oldUUID != newUUID {
                    Logger.verbose("oldUUID: \(oldUUID)")
                    Logger.verbose("newUUID: \(newUUID)")
                    Logger.warn("Cannot re-link with a different uuid.")
                    return Promise(error: AccountManagerError.reregistrationDifferentAccount)
                } else if oldUUID == newUUID {
                    // Secondary devices _can_ re-link to primaries with different
                    // phone numbers if the uuid is present and has not changed.
                    canChangePhoneNumbers = true
                }
            }
            // * Primary devices _cannot_ re-register with a new phone number.
            // * Secondary devices _cannot_ be re-linked to primaries with a different phone number
            //   unless the uuid is present and has not changed.
            if !canChangePhoneNumbers,
               let reregistrationPhoneNumber = tsAccountManager.reregistrationPhoneNumber(),
               reregistrationPhoneNumber != provisionMessage.phoneNumber {
                Logger.verbose("reregistrationPhoneNumber: \(reregistrationPhoneNumber)")
                Logger.verbose("provisionMessage.phoneNumber: \(provisionMessage.phoneNumber)")
                Logger.warn("Cannot re-register with a different phone number.")
                return Promise(error: AccountManagerError.reregistrationDifferentAccount)
            }
        }

        tsAccountManager.phoneNumberAwaitingVerification = provisionMessage.phoneNumber
        tsAccountManager.uuidAwaitingVerification = provisionMessage.aci
        tsAccountManager.pniAwaitingVerification = provisionMessage.pni

        let serverAuthToken = generateServerAuthToken()

        return firstly { () throws -> Promise<VerifySecondaryDeviceResponse> in
            let encryptedDeviceName = try DeviceNames.encryptDeviceName(
                plaintext: deviceName,
                identityKeyPair: provisionMessage.aciIdentityKeyPair)

            return accountServiceClient.verifySecondaryDevice(verificationCode: provisionMessage.provisioningCode,
                                                              phoneNumber: provisionMessage.phoneNumber,
                                                              authKey: serverAuthToken,
                                                              encryptedDeviceName: encryptedDeviceName)
        }.done { (response: VerifySecondaryDeviceResponse) in
            if let pniFromPrimary = self.tsAccountManager.pniAwaitingVerification {
                if pniFromPrimary != response.pni {
                    throw OWSAssertionError("primary PNI is out of sync with the server")
                }
            } else {
                self.tsAccountManager.pniAwaitingVerification = response.pni
            }

            self.databaseStorage.write { transaction in
                self.identityManager.storeIdentityKeyPair(provisionMessage.aciIdentityKeyPair,
                                                          for: .aci,
                                                          transaction: transaction)

                if let pniIdentityKeyPair = provisionMessage.pniIdentityKeyPair {
                    self.identityManager.storeIdentityKeyPair(pniIdentityKeyPair, for: .pni, transaction: transaction)
                }

                self.profileManagerImpl.setLocalProfileKey(provisionMessage.profileKey,
                                                           userProfileWriter: .linking,
                                                           authedAccount: .implicit(),
                                                           transaction: transaction)

                if let areReadReceiptsEnabled = provisionMessage.areReadReceiptsEnabled {
                    self.receiptManager.setAreReadReceiptsEnabled(areReadReceiptsEnabled,
                                                                      transaction: transaction)
                }

                self.tsAccountManager.setStoredServerAuthToken(serverAuthToken,
                                                               deviceId: response.deviceId,
                                                               transaction: transaction)

                self.tsAccountManager.setStoredDeviceName(deviceName,
                                                          transaction: transaction)
            }
        }.then { _ -> Promise<Void> in
            self.createPreKeys()
        }.then { _ -> Promise<Void> in
            return self.syncPushTokens().recover { error in
                switch error {
                case PushRegistrationError.pushNotSupported(let description):
                    // This can happen with:
                    // - simulators, none of which support receiving push notifications
                    // - on iOS11 devices which have disabled "Allow Notifications" and disabled "Enable Background Refresh" in the system settings.
                    Logger.info("Recovered push registration error. Leaving as manual message fetcher because push not supported: \(description)")

                    // no-op since secondary devices already start as manual message fetchers
                    return
                default:
                    throw error
                }
            }
        }.then(on: DispatchQueue.global()) {
            self.serviceClient.updateSecondaryDeviceCapabilities()
        }.done {
            self.completeRegistration()
        }.then { _ -> Promise<Void> in
            BenchEventStart(title: "waiting for initial storage service restore", eventId: "initial-storage-service-restore")

            self.databaseStorage.asyncWrite { transaction in
                OWSSyncManager.shared.sendKeysSyncRequestMessage(transaction: transaction)
            }

            let storageServiceRestorePromise = firstly {
                NotificationCenter.default.observe(once: .OWSSyncManagerKeysSyncDidComplete).asVoid()
            }.then {
                StorageServiceManager.shared.restoreOrCreateManifestIfNecessary(authedAccount: .implicit()).asVoid()
            }.ensure {
                BenchEventComplete(eventId: "initial-storage-service-restore")
            }.timeout(seconds: 60)

            // we wait a bit for the initial syncs to come in before proceeding to the inbox
            // because we want to present the inbox already populated with groups and contacts,
            // rather than have the trickle in moments later.
            // TODO: Eventually, we can rely entirely on the storage service and will no longer
            // need to do any initial sync beyond the "keys" sync. For now, we try and do both
            // operations in parallel.
            BenchEventStart(title: "waiting for initial contact and group sync", eventId: "initial-contact-sync")

            let initialSyncMessagePromise = firstly {
                OWSSyncManager.shared.sendInitialSyncRequestsAwaitingCreatedThreadOrdering(timeoutSeconds: 60)
            }.done(on: DispatchQueue.global() ) { orderedThreadIds in
                Logger.debug("orderedThreadIds: \(orderedThreadIds)")
                // Maintain the remote sort ordering of threads by inserting `syncedThread` messages
                // in that thread order.
                self.databaseStorage.write { transaction in
                    for threadId in orderedThreadIds.reversed() {
                        guard let thread = TSThread.anyFetch(uniqueId: threadId, transaction: transaction) else {
                            owsFailDebug("thread was unexpectedly nil")
                            continue
                        }
                        let message = TSInfoMessage(thread: thread,
                                                    messageType: .syncedThread)
                        message.anyInsert(transaction: transaction)
                    }
                }
            }.ensure {
                BenchEventComplete(eventId: "initial-contact-sync")
            }

            return Promise.when(fulfilled: [storageServiceRestorePromise, initialSyncMessagePromise])
        }
    }

    private struct RegistrationResponse {
        var aci: UUID
        var pni: UUID
        var hasPreviouslyUsedKBS = false
    }

    private func registerForTextSecure(verificationCode: String, pin: String?, checkForAvailableTransfer: Bool) -> Promise<RegistrationResponse> {
        let serverAuthToken = generateServerAuthToken()

        return Promise<Any?> { future in
            guard let phoneNumber = tsAccountManager.phoneNumberAwaitingVerification else {
                throw OWSAssertionError("phoneNumberAwaitingVerification was unexpectedly nil")
            }

            let accountAttributes = self.databaseStorage.write { transaction in
                return AccountAttributes.deprecated_generateForInitialRegistration(
                    fromDependencies: self,
                    keyBackupService: DependenciesBridge.shared.keyBackupService,
                    transaction: transaction
                )
            }

            let request = OWSRequestFactory.deprecated_verifyPrimaryDeviceRequest(
                verificationCode: verificationCode,
                phoneNumber: phoneNumber,
                authPassword: serverAuthToken,
                checkForAvailableTransfer: checkForAvailableTransfer,
                attributes: accountAttributes
            )

            tsAccountManager.verifyRegistration(request: request,
                                                success: future.resolve,
                                                failure: future.reject)
        }.map(on: DispatchQueue.global()) { responseObject throws -> RegistrationResponse in
            self.databaseStorage.write { transaction in
                self.tsAccountManager.setStoredServerAuthToken(serverAuthToken,
                                                               deviceId: OWSDevicePrimaryDeviceId,
                                                               transaction: transaction)
            }

            guard let responseObject = responseObject else {
                throw OWSAssertionError("Missing responseObject.")
            }

            guard let params = ParamParser(responseObject: responseObject) else {
                throw OWSAssertionError("Missing or invalid params.")
            }

            let aci: UUID = try params.required(key: "uuid")
            let pni: UUID = try params.required(key: "pni")
            let hasPreviouslyUsedKBS = try params.optional(key: "storageCapable") ?? false

            return RegistrationResponse(aci: aci, pni: pni, hasPreviouslyUsedKBS: hasPreviouslyUsedKBS)
        }
    }

    private func createPreKeys() -> Promise<Void> {
        return Promise { future in
            TSPreKeyManager.createPreKeys(success: { future.resolve() },
                                          failure: future.reject)
        }
    }

    private func syncPushTokens() -> Promise<Void> {
        Logger.info("")
        let job = SyncPushTokensJob(mode: .forceUpload)
        return job.run()
    }

    private func completeRegistration() {
        Logger.info("")
        tsAccountManager.didRegister()
    }

    // MARK: Message Delivery

    func updatePushTokens(pushToken: String, voipToken: String?) -> Promise<Void> {
        return Promise { future in
            tsAccountManager.registerForPushNotifications(pushToken: pushToken,
                                                          voipToken: voipToken,
                                                          success: { future.resolve() },
                                                          failure: future.reject)
        }
    }

    func updatePushTokens(request: TSRequest) -> Promise<Void> {
        return Promise { future in
            tsAccountManager.registerForPushNotifications(request: request,
                                                          success: { future.resolve() },
                                                          failure: future.reject)
        }
    }

    // MARK: Turn Server

    func getTurnServerInfo() -> Promise<TurnServerInfo> {
        let request = OWSRequestFactory.turnServerInfoRequest()
        return firstly {
            Self.networkManager.makePromise(request: request)
        }.map(on: DispatchQueue.global()) { response in
            guard let json = response.responseBodyJson,
                  let responseDictionary = json as? [String: AnyObject],
                  let turnServerInfo = TurnServerInfo(attributes: responseDictionary) else {
                throw OWSAssertionError("Missing or invalid JSON")
            }
            return turnServerInfo
        }
    }

    func recordUuidIfNecessary() {
        DispatchQueue.global().async {
            _ = self.ensureUuid().catch { error in
                // Until we're in a UUID-only world, don't require a
                // local UUID.
                owsFailDebug("error: \(error)")
            }
        }
    }

    func ensureUuid() -> Promise<UUID> {
        if let existingUuid = tsAccountManager.localUuid {
            return Promise.value(existingUuid)
        }

        return accountServiceClient.getAccountWhoAmI().map(on: DispatchQueue.global()) { whoAmIResponse in
            let uuid = whoAmIResponse.aci

            // It's possible this method could be called multiple times, so we check
            // again if it's been set. We dont bother serializing access since it should
            // be idempotent.
            if let existingUuid = self.tsAccountManager.localUuid {
                assert(existingUuid == uuid)
                return existingUuid
            }
            Logger.info("Recording UUID for legacy user")
            self.tsAccountManager.recordUuidForLegacyUser(uuid)
            return uuid
        }
    }

    private func generateServerAuthToken() -> String {
        return Cryptography.generateRandomBytes(16).hexadecimalString
    }
}
