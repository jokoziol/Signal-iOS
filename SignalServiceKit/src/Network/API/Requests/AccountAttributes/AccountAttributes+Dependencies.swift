//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension AccountAttributes {

    public static func generateForPrimaryDevice(
        fromDependencies dependencies: Dependencies,
        keyBackupService: KeyBackupService,
        transaction: SDSAnyWriteTransaction
    ) -> AccountAttributes {
        owsAssertDebug(dependencies.tsAccountManager.isPrimaryDevice)
        return generate(
            fromDependencies: dependencies,
            keyBackupService: keyBackupService,
            encryptedDeviceName: nil,
            isSecondaryDeviceRegistration: false,
            transaction: transaction
        )
    }

    public static func deprecated_generateForInitialRegistration(
        fromDependencies dependencies: Dependencies,
        keyBackupService: KeyBackupService,
        transaction: SDSAnyWriteTransaction
    ) -> AccountAttributes {
        owsAssertDebug(dependencies.tsAccountManager.isPrimaryDevice)
        return generate(
            fromDependencies: dependencies,
            keyBackupService: keyBackupService,
            encryptedDeviceName: nil,
            isSecondaryDeviceRegistration: false,
            transaction: transaction
        )
    }

    public static func generateForSecondaryDevice(
        fromDependencies dependencies: Dependencies,
        keyBackupService: KeyBackupService,
        encryptedDeviceName: Data,
        transaction: SDSAnyWriteTransaction
    ) -> AccountAttributes {
        return generate(
            fromDependencies: dependencies,
            keyBackupService: keyBackupService,
            encryptedDeviceName: encryptedDeviceName,
            isSecondaryDeviceRegistration: true,
            transaction: transaction
        )
    }

    private static func generate(
        fromDependencies dependencies: Dependencies,
        keyBackupService: KeyBackupService,
        encryptedDeviceName encryptedDeviceNameRaw: Data?,
        isSecondaryDeviceRegistration: Bool,
        transaction: SDSAnyWriteTransaction
    ) -> AccountAttributes {
        let isManualMessageFetchEnabled: Bool
        if isSecondaryDeviceRegistration {
            // Secondary devices only use account attributes during registration;
            // at this time they have historically set this to true.
            // Some forensic investigation is required as to why, but the best bet
            // is that some form of message delivery needs to succeed _before_ it
            // sets its APNS token, and thus it needs manual message fetch enabled.

            // This field is scoped to the device that sets it and does not overwrite
            // the attribute from the primary device.
            isManualMessageFetchEnabled = true
        } else {
            isManualMessageFetchEnabled = dependencies.tsAccountManager.isManualMessageFetchEnabled(transaction)
        }

        let registrationId = dependencies.tsAccountManager .getOrGenerateRegistrationId(transaction: transaction)
        let pniRegistrationId = dependencies.tsAccountManager .getOrGeneratePniRegistrationId(transaction: transaction)

        let profileKey = dependencies.profileManager.localProfileKey()
        let udAccessKey: String
        do {
            udAccessKey = try SMKUDAccessKey(profileKey: profileKey.keyData).keyData.base64EncodedString()
            guard udAccessKey.isEmpty.negated else {
                // Crash app if UD cannot be enabled.
                owsFail("Could not determine UD access key.")
            }
        } catch {
            // Crash app if UD cannot be enabled.
            owsFail("Could not determine UD access key: \(error).")
        }
        let allowUnrestrictedUD = dependencies.udManager.shouldAllowUnrestrictedAccessLocal(transaction: transaction)

        let twoFaMode: TwoFactorAuthMode
        if isSecondaryDeviceRegistration {
            // Historical note: secondary device registration uses the same AccountAttributes object,
            // but some fields, like reglock and pin, are ignored by the server.
            // Don't bother looking for KBS data the secondary couldn't possibly have at this point,
            // just explicitly set to nil.
            twoFaMode = .none
        } else {
            if
                let reglockToken = keyBackupService.deriveRegistrationLockToken(transaction: transaction.asV2Read),
                reglockToken.isEmpty.negated,
                dependencies.ows2FAManager.isRegistrationLockV2Enabled(transaction: transaction)
            {
                twoFaMode = .v2(reglockToken: reglockToken)
            } else if
                let pinCode = dependencies.ows2FAManager.pinCode(with: transaction),
                pinCode.isEmpty.negated,
                keyBackupService.hasBackedUpMasterKey(transaction: transaction.asV2Read).negated
            {
                twoFaMode = .v1(pinCode: pinCode)
            } else {
                twoFaMode = .none
            }
        }

        let registrationRecoveryPassword = keyBackupService.data(
            for: .registrationRecoveryPassword,
            transaction: transaction.asV2Read
        )?.base64EncodedString()

        let encryptedDeviceName = (encryptedDeviceNameRaw?.isEmpty ?? true) ? nil : encryptedDeviceNameRaw?.base64EncodedString()

        let isDiscoverableByPhoneNumber: Bool? = FeatureFlags.phoneNumberDiscoverability
            ? dependencies.tsAccountManager.isDiscoverableByPhoneNumber(with: transaction)
            : nil

        let hasKBSBackups = keyBackupService.hasBackedUpMasterKey(transaction: transaction.asV2Read)

        return AccountAttributes(
            isManualMessageFetchEnabled: isManualMessageFetchEnabled,
            registrationId: registrationId,
            pniRegistrationId: pniRegistrationId,
            unidentifiedAccessKey: udAccessKey,
            unrestrictedUnidentifiedAccess: allowUnrestrictedUD,
            twofaMode: twoFaMode,
            registrationRecoveryPassword: registrationRecoveryPassword,
            encryptedDeviceName: encryptedDeviceName,
            discoverableByPhoneNumber: isDiscoverableByPhoneNumber,
            hasKBSBackups: hasKBSBackups)
    }
}
