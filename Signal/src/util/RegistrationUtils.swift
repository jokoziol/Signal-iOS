//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit
import UIKit

@objc
public extension RegistrationUtils {

    static func reregister(fromViewController: UIViewController) {
        AssertIsOnMainThread()

        // If this is not the primary device, jump directly to the re-linking flow.
        guard self.tsAccountManager.isPrimaryDevice else {
            Self.showRelinkingUI()
            return
        }

        guard tsAccountManager.resetForReregistration(),
              let phoneNumber = Self.tsAccountManager.reregistrationPhoneNumber()?.nilIfEmpty,
              let e164 = E164(phoneNumber)
        else {
            owsFailDebug("could not reset for re-registration.")
            return
        }

        Logger.info("phoneNumber: \(phoneNumber)")

        Self.preferences.unsetRecordedAPNSTokens()

        if FeatureFlags.useNewRegistrationFlow {
            showReRegistration(e164: e164)
        } else {
            showLegacyReRegistration(fromViewController: fromViewController, e164: phoneNumber)
        }
    }

    private static func showLegacyReRegistration(fromViewController: UIViewController, e164: String) {
        ModalActivityIndicatorViewController.present(
            fromViewController: fromViewController,
            canCancel: false) { modalActivityIndicator in

                firstly {
                    Self.accountManager.deprecated_requestRegistrationVerification(e164: e164,
                                                                                   captchaToken: nil,
                                                                                   isSMS: true)
                }.done(on: DispatchQueue.main) { _ in

                    Logger.info("re-registering: send verification code succeeded.")

                    modalActivityIndicator.dismiss {
                        AssertIsOnMainThread()

                        // TODO[ViewContextPiping]
                        let context = ViewControllerContext.shared
                        let onboardingController = Deprecated_OnboardingController(context: context, onboardingMode: .registering)
                        let registrationPhoneNumber = Deprecated_RegistrationPhoneNumber(
                            e164: e164,
                            userInput: e164
                        )
                        onboardingController.update(phoneNumber: registrationPhoneNumber)

                        let viewController = Deprecated_OnboardingVerificationViewController(onboardingController: onboardingController)
                        viewController.hideBackLink()
                        let navigationController = Deprecated_OnboardingNavigationController(onboardingController: onboardingController)
                        navigationController.setViewControllers([viewController], animated: false)
                        let window: UIWindow = CurrentAppContext().mainWindow!
                        window.rootViewController = navigationController
                    }
                }.catch(on: DispatchQueue.main) { error in
                    AssertIsOnMainThread()

                    Logger.warn("Re-registration failure: \(error).")

                    modalActivityIndicator.dismiss {
                        AssertIsOnMainThread()

                        if error.httpStatusCode == 400 {
                            OWSActionSheets.showActionSheet(
                                title: NSLocalizedString("REGISTRATION_ERROR", comment: ""),
                                message: NSLocalizedString("REGISTRATION_NON_VALID_NUMBER", comment: "")
                            )
                        } else if let error = error as? UserErrorDescriptionProvider {
                            OWSActionSheets.showActionSheet(
                                title: NSLocalizedString("REGISTRATION_ERROR", comment: ""),
                                message: error.localizedDescription
                            )
                        } else if let error = error as? AccountServiceClientError {
                            switch error {
                            case .captchaRequired:
                                // TODO[ViewContextPiping]
                                let context = ViewControllerContext.shared
                                let onboardingController = Deprecated_OnboardingController(context: context, onboardingMode: .registering)
                                let registrationPhoneNumber = Deprecated_RegistrationPhoneNumber(
                                    e164: e164,
                                    userInput: e164
                                )
                                onboardingController.update(phoneNumber: registrationPhoneNumber)

                                let viewController = Deprecated_OnboardingCaptchaViewController(onboardingController: onboardingController)
                                let navigationController = Deprecated_OnboardingNavigationController(onboardingController: onboardingController)
                                navigationController.setViewControllers([viewController], animated: false)
                                let window: UIWindow = CurrentAppContext().mainWindow!
                                window.rootViewController = navigationController
                            }

                        } else {
                            OWSActionSheets.showActionSheet(
                                title: NSLocalizedString("REGISTRATION_ERROR", comment: "")
                                )
                        }
                    }
                }
            }
    }
}

extension RegistrationUtils {

    fileprivate static func showReRegistration(e164: E164) {
        let dependencies = RegistrationCoordinatorDependencies.from(NSObject())
        let desiredMode = RegistrationMode.reRegistering(e164: e164)
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
}
