//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalMessaging
import SignalServiceKit
import SignalUI

@objc
class AccountSettingsViewController: OWSTableViewController2 {

    private let context: ViewControllerContext

    override init() {
        // TODO[ViewContextPiping]
        self.context = ViewControllerContext.shared
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("SETTINGS_ACCOUNT", comment: "Title for the 'account' link in settings.")

        updateTableContents()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        updateTableContents()
        tableView.layoutIfNeeded()
    }

    func updateTableContents() {
        let contents = OWSTableContents()

        // Show the change pin and reglock sections
        if tsAccountManager.isRegisteredPrimaryDevice {
            let pinSection = OWSTableSection()
            pinSection.headerTitle = NSLocalizedString(
                "SETTINGS_PINS_TITLE",
                comment: "Title for the 'PINs' section of the privacy settings."
            )
            pinSection.footerAttributedTitle = NSAttributedString.composed(of: [
                NSLocalizedString(
                    "SETTINGS_PINS_FOOTER",
                    comment: "Footer for the 'PINs' section of the privacy settings."
                ),
                " ",
                CommonStrings.learnMore.styled(with: .link(URL(string: "https://support.signal.org/hc/articles/360007059792")!))
            ]).styled(
                with: .font(.dynamicTypeCaption1Clamped),
                .color(Theme.secondaryTextAndIconColor)
            )

            pinSection.add(.disclosureItem(
                withText: OWS2FAManager.shared.is2FAEnabled()
                    ? NSLocalizedString(
                        "SETTINGS_PINS_ITEM",
                        comment: "Label for the 'pins' item of the privacy settings when the user does have a pin."
                    )
                    : NSLocalizedString(
                        "SETTINGS_PINS_ITEM_CREATE",
                        comment: "Label for the 'pins' item of the privacy settings when the user doesn't have a pin."
                    ),
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "pin"),
                actionBlock: { [weak self] in
                    self?.showCreateOrChangePin()
                }
            ))

            // Reminders toggle.
            if OWS2FAManager.shared.is2FAEnabled() {
                pinSection.add(.switch(
                    withText: NSLocalizedString(
                        "SETTINGS_PIN_REMINDER_SWITCH_LABEL",
                        comment: "Label for the 'pin reminder' switch of the privacy settings."
                    ),
                    isOn: { OWS2FAManager.shared.areRemindersEnabled },
                    isEnabledBlock: { true },
                    target: self,
                    selector: #selector(arePINRemindersEnabledDidChange)
                ))
            }

            contents.addSection(pinSection)

            let regLockSection = OWSTableSection()
            regLockSection.footerTitle = NSLocalizedString(
                "SETTINGS_TWO_FACTOR_PINS_AUTH_FOOTER",
                comment: "Footer for the 'two factor auth' section of the privacy settings when Signal PINs are available."
            )

            regLockSection.add(.switch(
                withText: NSLocalizedString(
                    "SETTINGS_TWO_FACTOR_AUTH_SWITCH_LABEL",
                    comment: "Label for the 'enable registration lock' switch of the privacy settings."
                ),
                isOn: { OWS2FAManager.shared.isRegistrationLockV2Enabled },
                isEnabledBlock: { true },
                target: self,
                selector: #selector(isRegistrationLockV2EnabledDidChange)
            ))

            contents.addSection(regLockSection)

            let advancedSection = OWSTableSection()
            advancedSection.add(.disclosureItem(
                withText: NSLocalizedString(
                    "SETTINGS_ADVANCED_PIN_SETTINGS",
                    comment: "Label for the 'advanced pin settings' button."
                ),
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "advanced-pins"),
                actionBlock: { [weak self] in
                    let vc = AdvancedPinSettingsTableViewController()
                    self?.navigationController?.pushViewController(vc, animated: true)
                }
            ))
            contents.addSection(advancedSection)
        }

        let accountSection = OWSTableSection()
        accountSection.headerTitle = NSLocalizedString("SETTINGS_ACCOUNT", comment: "Title for the 'account' link in settings.")

        if tsAccountManager.isDeregistered {
            accountSection.add(.actionItem(
                withText: tsAccountManager.isPrimaryDevice
                    ? NSLocalizedString("SETTINGS_REREGISTER_BUTTON", comment: "Label for re-registration button.")
                    : NSLocalizedString("SETTINGS_RELINK_BUTTON", comment: "Label for re-link button."),
                textColor: .ows_accentBlue,
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "reregister"),
                actionBlock: { [weak self] in
                    self?.reregisterUser()
                }
            ))
            accountSection.add(.actionItem(
                withText: NSLocalizedString("SETTINGS_DELETE_DATA_BUTTON",
                                            comment: "Label for 'delete data' button."),
                textColor: .ows_accentRed,
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "delete_data"),
                actionBlock: { [weak self] in
                    self?.deleteUnregisterUserData()
                }
            ))
        } else if tsAccountManager.isRegisteredPrimaryDevice {
            switch self.changeNumberState() {
            case .disallowed:
                break
            case .allowed:
                accountSection.add(.actionItem(
                    withText: NSLocalizedString("SETTINGS_CHANGE_PHONE_NUMBER_BUTTON", comment: "Label for button in settings views to change phone number"),
                    accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "change_phone_number"),
                    actionBlock: { [weak self] in
                        guard let self else {
                            return
                        }
                        // Fetch the state again in case it changed from under us
                        // between when the button was rendered and when it was tapped.
                        switch self.changeNumberState() {
                        case .disallowed:
                            return
                        case .allowed(let changeNumberParams):
                            self.changePhoneNumber(changeNumberParams)
                        }
                    }
                ))
            }
            accountSection.add(.actionItem(
                withText: NSLocalizedString(
                    "SETTINGS_ACCOUNT_DATA_REPORT_BUTTON",
                    comment: "Label for button in settings to get your account data report"
                ),
                accessibilityIdentifier: UIView.accessibilityIdentifier(
                    in: self,
                    name: "request_account_data_report"
                ),
                actionBlock: { [weak self] in
                    self?.requestAccountDataReport()
                }
            ))
            accountSection.add(.actionItem(
                withText: NSLocalizedString("SETTINGS_DELETE_ACCOUNT_BUTTON", comment: ""),
                textColor: .ows_accentRed,
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "delete_account"),
                actionBlock: { [weak self] in
                    self?.unregisterUser()
                }
            ))
        } else {
            accountSection.add(.actionItem(
                withText: NSLocalizedString("SETTINGS_DELETE_DATA_BUTTON",
                                            comment: "Label for 'delete data' button."),
                textColor: .ows_accentRed,
                accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "delete_data"),
                actionBlock: { [weak self] in
                    self?.deleteLinkedData()
                }
            ))
        }

        contents.addSection(accountSection)

        self.contents = contents
    }

    // MARK: - Account

    private func reregisterUser() {
        RegistrationUtils.showReregistrationUI(from: self)
    }

    private func deleteLinkedData() {
        OWSActionSheets.showConfirmationAlert(
            title: NSLocalizedString("CONFIRM_DELETE_LINKED_DATA_TITLE", comment: ""),
            message: NSLocalizedString("CONFIRM_DELETE_LINKED_DATA_TEXT", comment: ""),
            proceedTitle: NSLocalizedString("PROCEED_BUTTON", comment: ""),
            proceedStyle: .destructive
        ) { _ in
            SignalApp.resetAppDataWithUI()
        }
    }

    private func unregisterUser() {
        let vc = DeleteAccountConfirmationViewController()
        presentFormSheet(OWSNavigationController(rootViewController: vc), animated: true)
    }

    private func deleteUnregisterUserData() {
        OWSActionSheets.showConfirmationAlert(
            title: NSLocalizedString("CONFIRM_DELETE_DATA_TITLE", comment: ""),
            message: NSLocalizedString("CONFIRM_DELETE_DATA_TEXT", comment: ""),
            proceedTitle: NSLocalizedString("PROCEED_BUTTON", comment: ""),
            proceedStyle: .destructive
        ) { _ in
            SignalApp.resetAppDataWithUI()
        }
    }

    private func requestAccountDataReport() {
        let vc = RequestAccountDataReportViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    private func deprecated_changePhoneNumber() {
        let changePhoneNumberController = Deprecated_ChangePhoneNumberController(delegate: self)
        let vc = changePhoneNumberController.firstViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    enum ChangeNumberState {
        case disallowed
        case allowed(RegistrationMode.ChangeNumberParams)
    }

    private func changeNumberState() -> ChangeNumberState {
        return databaseStorage.read { transaction -> ChangeNumberState in
            guard self.legacyChangePhoneNumber.localUserSupportsChangePhoneNumber(transaction: transaction) else {
                return .disallowed
            }
            guard self.tsAccountManager.isDeregistered(transaction: transaction).negated else {
                return .disallowed
            }
            let loader = RegistrationCoordinatorLoaderImpl(dependencies: .from(self))
            switch loader.restoreLastMode(transaction: transaction.asV2Read) {
            case .none, .changingNumber:
                break
            case .registering, .reRegistering:
                // Don't allow changing number if we are in the middle of registering.
                return .disallowed
            }
            guard
                let localAddress = tsAccountManager.localAddress(with: transaction),
                let localAci = localAddress.uuid,
                let localE164 = localAddress.e164,
                let authToken = tsAccountManager.storedServerAuthToken(transaction: transaction),
                let localRecipient = SignalRecipient.get(
                    address: localAddress,
                    mustHaveDevices: false,
                    transaction: transaction
                ),
                let localUserAllDeviceIds = localRecipient.deviceIds,
                let localAccountId = localRecipient.accountId
            else {
                return .disallowed
            }
            let localDeviceId = tsAccountManager.storedDeviceId(transaction: transaction)

            return .allowed(RegistrationMode.ChangeNumberParams(
                oldE164: localE164,
                oldAuthToken: authToken,
                localAci: localAci,
                localAccountId: localAccountId,
                localDeviceId: localDeviceId,
                localUserAllDeviceIds: localUserAllDeviceIds
            ))
        }
    }

    private func changePhoneNumber(_ params: RegistrationMode.ChangeNumberParams) {
        Logger.info("Attempting to start change number from settings")
        let dependencies = RegistrationCoordinatorDependencies.from(NSObject())
        let desiredMode = RegistrationMode.changingNumber(params)
        let loader = RegistrationCoordinatorLoaderImpl(dependencies: dependencies)
        let coordinator = databaseStorage.write {
            return loader.coordinator(
                forDesiredMode: desiredMode,
                transaction: $0.asV2Write
            )
        }
        let navController = RegistrationNavigationController.withCoordinator(coordinator)
        let window: UIWindow = CurrentAppContext().mainWindow!
        window.rootViewController = navController
    }

    // MARK: - PINs

    @objc
    func arePINRemindersEnabledDidChange(_ sender: UISwitch) {
        if sender.isOn {
            databaseStorage.write { transaction in
                OWS2FAManager.shared.setAreRemindersEnabled(true, transaction: transaction)
            }
        } else {
            let pinConfirmationVC = PinConfirmationViewController(
                title: NSLocalizedString(
                    "SETTINGS_PIN_REMINDER_DISABLE_CONFIRMATION_TITLE",
                    comment: "The title for the dialog asking user to confirm their PIN to disable reminders"
                ),
                explanation: NSLocalizedString(
                    "SETTINGS_PIN_REMINDER_DISABLE_CONFIRMATION_EXPLANATION",
                    comment: "The explanation for the dialog asking user to confirm their PIN to disable reminders"
                ),
                actionText: NSLocalizedString(
                    "SETTINGS_PIN_REMINDER_DISABLE_CONFIRMATION_ACTION",
                    comment: "The button text for the dialog asking user to confirm their PIN to disable reminders"
                )
            ) { [weak self] confirmed in
                guard let self = self else { return }
                if confirmed {
                    self.databaseStorage.write { transaction in
                        OWS2FAManager.shared.setAreRemindersEnabled(false, transaction: transaction)
                    }

                    ExperienceUpgradeManager.dismissPINReminderIfNecessary()
                } else {
                    self.updateTableContents()
                }
            }
            present(pinConfirmationVC, animated: true)
        }
    }

    @objc
    func isRegistrationLockV2EnabledDidChange(_ sender: UISwitch) {
        let shouldBeEnabled = sender.isOn

        guard shouldBeEnabled != OWS2FAManager.shared.isRegistrationLockV2Enabled else { return }

        let actionSheet: ActionSheetController
        if shouldBeEnabled {
            actionSheet = ActionSheetController(
                title: NSLocalizedString(
                    "SETTINGS_REGISTRATION_LOCK_TURN_ON_TITLE",
                    comment: "Title for the alert confirming that the user wants to turn on registration lock."
                ),
                message: NSLocalizedString(
                    "SETTINGS_REGISTRATION_LOCK_TURN_ON_MESSAGE",
                    comment: "Body for the alert confirming that the user wants to turn on registration lock."
                )
            )

            let turnOnAction = ActionSheetAction(title: NSLocalizedString(
                "SETTINGS_REGISTRATION_LOCK_TURN_ON",
                comment: "Action to turn on registration lock"
            )) { [weak self] _ in
                if OWS2FAManager.shared.is2FAEnabled() {
                    OWS2FAManager.shared.enableRegistrationLockV2().done {
                        self?.updateTableContents()
                    }.catch { error in
                        owsFailDebug("Error enabling reglock \(error)")
                    }
                } else {
                    self?.showCreatePin(enableRegistrationLock: true)
                }
            }
            actionSheet.addAction(turnOnAction)
        } else {
            actionSheet = ActionSheetController(title: NSLocalizedString(
                "SETTINGS_REGISTRATION_LOCK_TURN_OFF_TITLE",
                comment: "Title for the alert confirming that the user wants to turn off registration lock."
            ))

            let turnOffAction = ActionSheetAction(
                title: NSLocalizedString(
                    "SETTINGS_REGISTRATION_LOCK_TURN_OFF",
                    comment: "Action to turn off registration lock"
                ),
                style: .destructive
            ) { [weak self] _ in
                OWS2FAManager.shared.disableRegistrationLockV2().done {
                    self?.updateTableContents()
                }.catch { error in
                    owsFailDebug("Failed to disable reglock \(error)")
                }
            }
            actionSheet.addAction(turnOffAction)
        }

        let cancelAction = ActionSheetAction(
            title: CommonStrings.cancelButton,
            style: .cancel
        ) { _ in
            sender.setOn(!shouldBeEnabled, animated: true)
        }
        actionSheet.addAction(cancelAction)

        presentActionSheet(actionSheet)
    }

    public func showCreateOrChangePin() {
        if OWS2FAManager.shared.is2FAEnabled() {
            showChangePin()
        } else {
            showCreatePin()
        }
    }

    private func showChangePin() {
        let vc = PinSetupViewController(mode: .changing, hideNavigationBar: false) { [weak self] _, _ in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
        }
        navigationController?.pushViewController(vc, animated: true)
    }

    private func showCreatePin(enableRegistrationLock: Bool = false) {
        let vc = PinSetupViewController(
            mode: .creating,
            hideNavigationBar: false,
            enableRegistrationLock: enableRegistrationLock
        ) { [weak self] _, _ in
            guard let self = self else { return }
            self.navigationController?.popToViewController(self, animated: true)
        }
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: -

extension AccountSettingsViewController: Deprecated_ChangePhoneNumberViewDelegate {
    var changePhoneNumberViewFromViewController: UIViewController { self }
}
