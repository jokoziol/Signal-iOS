//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalUI
import SignalServiceKit
import SignalMessaging

class DonateChoosePaymentMethodSheet: OWSTableSheetViewController {
    enum DonationMode {
        case oneTime
        case monthly
        case gift(recipientFullName: String)
    }

    private let amount: FiatMoney
    private let badge: ProfileBadge
    private let donationMode: DonationMode
    private let supportedPaymentMethods: Set<DonationPaymentMethod>
    private let didChoosePaymentMethod: (DonateChoosePaymentMethodSheet, DonationPaymentMethod) -> Void

    private let buttonHeight: CGFloat = 48

    private var titleText: String {
        let currencyString = DonationUtilities.format(money: amount)
        switch donationMode {
        case .oneTime:
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_TITLE_FOR_ONE_TIME_DONATION",
                comment: "When users make one-time donations, they see a sheet that lets them pick a payment method. This is the title on that sheet. Embeds {{amount of money}}, such as \"$5\"."
            )
            return String(format: format, currencyString)
        case .monthly:
            let moneyPerMonthFormat = NSLocalizedString(
                "SUSTAINER_VIEW_PRICING",
                comment: "Pricing text for sustainer view badges, embeds {{price}}"
            )
            let moneyPerMonthString = String(format: moneyPerMonthFormat, currencyString)
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_TITLE_FOR_MONTHLY_DONATION",
                comment: "When users make monthly donations, they see a sheet that lets them pick a payment method. This is the title on that sheet. Embeds {{amount of money per month}}, such as \"$5/month\"."
            )
            return String(format: format, moneyPerMonthString)
        case .gift:
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_TITLE_FOR_DONATION_ON_BEHALF_OF_A_FRIEND",
                comment: "When users make donations on a friend's behalf, they see a sheet that lets them pick a payment method. This is the title on that sheet. Embeds {{amount of money}}, such as \"$5\"."
            )
            return String(format: format, currencyString)
        }
    }

    private var bodyText: String? {
        switch donationMode {
        case .oneTime:
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_SUBTITLE_FOR_ONE_TIME_DONATION",
                comment: "When users make one-time donations, they see a sheet that lets them pick a payment method. It also tells them what they'll be doing when they pay: receive a badge for a month. This is the subtitle on that sheet. Embeds {{localized badge name}}, such as \"Boost\"." )
            return String(format: format, badge.localizedName)

        case .monthly:
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_SUBTITLE_FOR_MONTHLY_DONATION",
                comment: "When users make monthly donations, they see a sheet that lets them pick a payment method. It also tells them what they'll be doing when they pay: receive a badge. This is the subtitle on that sheet. Embeds {{localized badge name}}, such as \"Planet\"."
            )
            return String(format: format, badge.localizedName)

        case let .gift(recipientFullName):
            let format = NSLocalizedString(
                "DONATE_CHOOSE_PAYMENT_METHOD_SHEET_SUBTITLE_FOR_DONATION_ON_BEHALF_OF_A_FRIEND",
                comment: "When users make donations on a friend's behalf, they see a sheet that lets them pick a payment method. This is the subtitle on that sheet. Embeds {{recipient's name}}."
            )
            return String(format: format, recipientFullName)
        }
    }

    init(
        amount: FiatMoney,
        badge: ProfileBadge,
        donationMode: DonationMode,
        supportedPaymentMethods: Set<DonationPaymentMethod>,
        didChoosePaymentMethod: @escaping (DonateChoosePaymentMethodSheet, DonationPaymentMethod) -> Void
    ) {
        self.amount = amount
        self.badge = badge
        self.donationMode = donationMode
        self.supportedPaymentMethods = supportedPaymentMethods
        self.didChoosePaymentMethod = didChoosePaymentMethod

        super.init()
    }

    required init() {
        owsFail("init() has not been implemented")
    }

    // MARK: - Updating table contents

    public override func updateTableContents(shouldReload: Bool = true) {
        updateTop(shouldReload: shouldReload)
        updateBottom()
    }

    private func updateTop(shouldReload: Bool) {
        let infoStackView: UIView = {
            let stackView = UIStackView()
            stackView.axis = .vertical
            stackView.alignment = .center
            stackView.spacing = 6

            if let assets = badge.assets {
                let badgeImageView = UIImageView(image: assets.universal112)
                badgeImageView.autoSetDimensions(to: CGSize(square: 112))
                stackView.addArrangedSubview(badgeImageView)
                stackView.setCustomSpacing(12, after: badgeImageView)
            }

            let titleLabel = UILabel()
            titleLabel.font = .dynamicTypeTitle2.semibold()
            titleLabel.textColor = Theme.primaryTextColor
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 0
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.text = titleText
            stackView.addArrangedSubview(titleLabel)

            if let bodyText = bodyText {
                let bodyLabel = UILabel()
                bodyLabel.font = .dynamicTypeBody
                bodyLabel.textColor = Theme.primaryTextColor
                bodyLabel.textAlignment = .center
                bodyLabel.numberOfLines = 0
                bodyLabel.lineBreakMode = .byWordWrapping
                bodyLabel.text = bodyText
                stackView.addArrangedSubview(bodyLabel)
            }

            return stackView
        }()

        let section = OWSTableSection(items: [.init(customCellBlock: {
            let cell = OWSTableItem.newCell()
            cell.contentView.addSubview(infoStackView)
            infoStackView.autoPinEdgesToSuperviewMargins()
            return cell
        })])
        section.hasBackground = false
        section.shouldDisableCellSelection = true
        let contents = OWSTableContents(sections: [section])

        self.tableViewController.setContents(contents, shouldReload: shouldReload)
    }

    private func updateBottom() {
        let paymentButtonContainerView: UIView = {
            var paymentMethodButtons = [UIView]()

            if supportedPaymentMethods.contains(.applePay) {
                paymentMethodButtons.append(ApplePayButton { [weak self] in
                    guard let self else { return }
                    self.didChoosePaymentMethod(self, .applePay)
                })
            }

            if supportedPaymentMethods.contains(.paypal) {
                paymentMethodButtons.append(PaypalButton { [weak self] in
                    guard let self else { return }
                    self.didChoosePaymentMethod(self, .paypal)
                })
            }

            if supportedPaymentMethods.contains(.creditOrDebitCard) {
                let title = NSLocalizedString(
                    "DONATE_CHOOSE_CREDIT_OR_DEBIT_CARD_AS_PAYMENT_METHOD",
                    comment: "When users make donations, they can choose which payment method they want to use. This is the text on the button that lets them choose to pay with credit or debit card."
                )

                let creditOrDebitCardButton = OWSButton(title: title) { [weak self] in
                    guard let self else { return }
                    self.didChoosePaymentMethod(self, .creditOrDebitCard)
                }
                guard let image = UIImage(named: "credit-or-debit-card") else {
                    owsFail("Card asset not found")
                }
                creditOrDebitCardButton.setImage(image, for: .normal)
                creditOrDebitCardButton.setPaddingBetweenImageAndText(
                    to: 8,
                    isRightToLeft: CurrentAppContext().isRTL
                )
                creditOrDebitCardButton.layer.cornerRadius = 12
                creditOrDebitCardButton.backgroundColor = .ows_accentBlue
                creditOrDebitCardButton.dimsWhenHighlighted = true
                creditOrDebitCardButton.titleLabel?.font = .dynamicTypeBody.semibold()
                paymentMethodButtons.append(creditOrDebitCardButton)
            }

            owsAssert(!paymentMethodButtons.isEmpty, "Expected at least one payment method")

            let stackView = UIStackView(arrangedSubviews: paymentMethodButtons)
            stackView.axis = .vertical
            stackView.alignment = .fill
            stackView.spacing = 12

            for button in paymentMethodButtons {
                button.autoSetDimension(.height, toSize: buttonHeight)
            }

            return stackView
        }()

        footerStack.removeAllSubviews()
        footerStack.addArrangedSubview(paymentButtonContainerView)
        footerStack.alignment = .fill
        footerStack.layoutMargins = UIEdgeInsets(top: 28, left: 20, bottom: 8, right: 20)
        footerStack.isLayoutMarginsRelativeArrangement = true

        paymentButtonContainerView.autoPinWidthToSuperviewMargins()
    }
}
