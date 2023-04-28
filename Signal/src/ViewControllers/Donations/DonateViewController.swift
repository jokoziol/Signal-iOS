//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import PassKit
import Lottie
import SignalUI
import SignalServiceKit
import SignalMessaging

class DonateViewController: OWSViewController, OWSNavigationChildController {
    private static func canMakeNewDonations(
        forDonateMode donateMode: DonateMode
    ) -> Bool {
        DonationUtilities.canDonate(
            inMode: donateMode.asDonationMode,
            localNumber: tsAccountManager.localNumber
        )
    }

    private var backgroundColor: UIColor {
        OWSTableViewController2.tableBackgroundColor(isUsingPresentedStyle: true)
    }
    static let cornerRadius: CGFloat = 18
    static var bubbleBackgroundColor: CGColor { DonationViewsUtil.bubbleBackgroundColor.cgColor }
    static var selectedColor: CGColor { Theme.accentBlueColor.cgColor }

    public var preferredNavigationBarStyle: OWSNavigationBarStyle { .solid }
    public var navbarBackgroundColorOverride: UIColor? { .clear }

    private static func commonStack() -> UIStackView {
        let result = UIStackView()
        result.axis = .vertical
        result.alignment = .fill
        result.spacing = 20
        return result
    }

    // MARK: - Initialization

    internal var state: State {
        didSet {
            Logger.info("[Donations] DonateViewController state changed to \(state.debugDescription)")
            render(oldState: oldValue)
        }
    }

    enum FinishResult {
        case completedDonation(donateSheet: DonateViewController, badgeThanksSheet: BadgeThanksSheet)
        case monthlySubscriptionCancelled(donateSheet: DonateViewController, toastText: String)
    }
    internal let onFinished: (FinishResult) -> Void

    private var scrollToOneTimeContinueButtonWhenKeyboardAppears = false

    public init(
        preferredDonateMode: DonateMode,
        onFinished: @escaping (FinishResult) -> Void
    ) {
        if Self.canMakeNewDonations(forDonateMode: preferredDonateMode) {
            self.state = .init(donateMode: preferredDonateMode)
        } else {
            self.state = .init(donateMode: .monthly)
        }
        self.onFinished = onFinished

        super.init()
    }

    // MARK: - View callbacks

    public override func viewDidLoad() {
        super.viewDidLoad()

        let isPresentedStandalone = navigationController?.viewControllers.first == self
        if isPresentedStandalone {
            navigationItem.leftBarButtonItem = .init(
                barButtonSystemItem: .cancel,
                target: self,
                action: #selector(didTapCancel)
            )
        }

        render(oldState: nil)
        loadAndUpdateState()

        scrollView.addSubview(stackView)
        stackView.autoPinWidth(toWidthOf: scrollView)
        stackView.autoPinHeightToSuperview()

        let margin: CGFloat = 20
        stackView.layoutMargins = .init(top: 0, leading: margin, bottom: margin, trailing: margin)
        stackView.isLayoutMarginsRelativeArrangement = true

        view.addSubview(scrollView)
        scrollView.autoPinWidthToSuperview()
        scrollView.autoPinEdge(toSuperviewEdge: .top)
        scrollView.autoPinEdge(.bottom, to: .bottom, of: keyboardLayoutGuideViewSafeArea)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didKeyboardShow),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
    }

    public override func themeDidChange() {
        super.themeDidChange()
        render(oldState: nil)
    }

    // MARK: - Events

    @objc
    private func didTapCancel() {
        dismiss(animated: true)
    }

    @objc
    private func didDonateModeChange() {
        let rawValue = donateModePickerView.selectedSegmentIndex
        guard let newValue = DonateMode(rawValue: rawValue) else {
            owsFail("[Donations] Unexpected donate mode")
        }
        state = state.selectDonateMode(newValue)
    }

    private func addAnimationView(anchor: UIView, name: String) {
        if UIAccessibility.isReduceMotionEnabled { return }

        let animationView = AnimationView(name: name)
        animationView.loopMode = .playOnce
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundBehavior = .forceFinish
        animationView.isUserInteractionEnabled = false
        stackView.addSubview(animationView)
        animationView.autoPinEdge(.bottom, to: .top, of: anchor, withOffset: 30)
        animationView.autoPinEdge(.leading, to: .leading, of: anchor)
        animationView.autoMatch(.width, to: .width, of: anchor)
        animationView.play { _ in
            animationView.removeFromSuperview()
        }
    }

    private func didSelectOneTimeAmount(
        amount: FiatMoney,
        animationAnchor: UIView,
        animationName: String
    ) {
        state = state.selectOneTimeAmount(.selectedPreset(amount: amount))
        addAnimationView(anchor: animationAnchor, name: animationName)
    }

    @objc
    private func didKeyboardShow() {
        if scrollToOneTimeContinueButtonWhenKeyboardAppears {
            scrollView.scrollIntoView(subview: oneTimeContinueButton)
            scrollToOneTimeContinueButtonWhenKeyboardAppears = false
        }
    }

    @objc
    private func didTapOneTimeCustomAmountTextField() {
        guard let oneTime = state.oneTime else {
            owsFail("[Donations] Expected one-time state but it was not loaded")
        }

        switch oneTime.selectedAmount {
        case .nothingSelected, .selectedPreset:
            state = state.selectOneTimeAmount(.choseCustomAmount(
                amount: FiatMoney(currencyCode: oneTime.selectedCurrencyCode, value: 0)
            ))
        case .choseCustomAmount:
            break
        }

        oneTimeCustomAmountTextField.becomeFirstResponder()
        scrollToOneTimeContinueButtonWhenKeyboardAppears = true
    }

    @objc
    private func didTapMonthlySubscriptionLevelView(_ sender: UIGestureRecognizer) {
        guard let view = sender.view as? MonthlySubscriptionLevelView else {
            owsFail("[Donations] Tapped something other than a monthly subscription level view")
        }
        state = state.selectSubscriptionLevel(view.subscriptionLevel)
        addAnimationView(anchor: view, name: view.animationName)
    }

    private func startApplePay(
        with amount: FiatMoney,
        donateMode: DonateMode
    ) {
        let paymentRequest = DonationUtilities.newPaymentRequest(
            for: amount,
            isRecurring: {
                switch donateMode {
                case .oneTime: return false
                case .monthly: return true
                }
            }()
        )
        let paymentController = PKPaymentAuthorizationController(paymentRequest: paymentRequest)
        paymentController.delegate = self
        paymentController.present { presented in
            if !presented {
                // This can happen under normal conditions if the user double-taps the button,
                // but may also indicate a problem.
                Logger.warn("[Donations] Failed to present payment controller")
            }
        }
    }

    private func startCreditOrDebitCard(
        with amount: FiatMoney,
        badge: ProfileBadge?,
        donateMode: DonateMode
    ) {
        guard let navigationController else {
            owsFail("[Donations] Cannot open credit/debit card screen if we're not in a navigation controller")
        }

        guard let badge else {
            owsFail("[Donations] Missing badge")
        }

        let cardDonationMode: CreditOrDebitCardDonationViewController.DonationMode
        switch donateMode {
        case .oneTime:
            cardDonationMode = .oneTime
        case .monthly:
            guard
                let monthly = state.monthly,
                let subscriptionLevel = monthly.selectedSubscriptionLevel
            else {
                owsFail("[Donations] Cannot update monthly donation. This should be prevented in the UI")
            }
            cardDonationMode = .monthly(
                subscriptionLevel: subscriptionLevel,
                subscriberID: monthly.subscriberID,
                currentSubscription: monthly.currentSubscription,
                currentSubscriptionLevel: monthly.currentSubscriptionLevel
            )
        }

        let badgesSnapshot = BadgeThanksSheet.currentProfileBadgesSnapshot()

        let vc = CreditOrDebitCardDonationViewController(
            donationAmount: amount,
            donationMode: cardDonationMode
        ) { [weak self] in
            self?.didCompleteDonation(
                badge: badge,
                thanksSheetType: donateMode.forBadgeThanksSheet,
                oldBadgesSnapshot: badgesSnapshot
            )
        }
        navigationController.pushViewController(vc, animated: true)
    }

    private func startPaypal(
        with amount: FiatMoney,
        badge: ProfileBadge?,
        donateMode: DonateMode
    ) {
        guard let badge else {
            owsFail("[Donations] Missing badge!")
        }

        switch donateMode {
        case .oneTime:
            startPaypalBoost(with: amount, badge: badge)
        case .monthly:
            startPaypalSubscription(with: amount, badge: badge)
        }
    }

    private func presentChoosePaymentMethodSheet(
        amount: FiatMoney,
        badge: ProfileBadge,
        donateMode: DonateMode,
        supportedPaymentMethods: Set<DonationPaymentMethod>
    ) {
        oneTimeCustomAmountTextField.resignFirstResponder()

        let sheet = DonateChoosePaymentMethodSheet(
            amount: amount,
            badge: badge,
            donationMode: donateMode.forChoosePaymentMethodSheet,
            supportedPaymentMethods: supportedPaymentMethods
        ) { [weak self] (sheet, paymentMethod) in
            sheet.dismiss(animated: true) { [weak self] in
                guard let self else { return }

                switch paymentMethod {
                case .applePay:
                    self.startApplePay(with: amount, donateMode: donateMode)
                case .creditOrDebitCard:
                    self.startCreditOrDebitCard(
                        with: amount,
                        badge: badge,
                        donateMode: donateMode
                    )
                case .paypal:
                    self.startPaypal(
                        with: amount,
                        badge: badge,
                        donateMode: donateMode
                    )
                }
            }
        }

        present(sheet, animated: true)
    }

    private func didTapToContinueOneTimeDonation() {
        guard let oneTime = state.oneTime else {
            owsFail("[Donations] Expected the one-time state to be loaded. This should be impossible in the UI")
        }

        func showError(_ text: String) {
            let actionSheet = ActionSheetController(message: text)
            actionSheet.addAction(.init(
                title: CommonStrings.okayButton,
                style: .cancel,
                handler: nil
            ))
            presentActionSheet(actionSheet)
        }

        switch oneTime.paymentRequest {
        case .noAmountSelected:
            showError(NSLocalizedString(
                "DONATE_SCREEN_ERROR_NO_AMOUNT_SELECTED",
                comment: "If the user tries to donate to Signal but no amount is selected, this error message is shown."
            ))
        case let .amountIsTooSmall(minimumAmount):
            let format = NSLocalizedString(
                "DONATE_SCREEN_ERROR_SELECT_A_LARGER_AMOUNT_FORMAT",
                comment: "If the user tries to donate to Signal but they've entered an amount that's too small, this error message is shown. Embeds {{currency string}}, such as \"$5\"."
            )
            let currencyString = DonationUtilities.format(money: minimumAmount)
            showError(String(format: format, currencyString))
        case let .canContinue(amount, supportedPaymentMethods):
            presentChoosePaymentMethodSheet(
                amount: amount,
                badge: oneTime.profileBadge,
                donateMode: .oneTime,
                supportedPaymentMethods: supportedPaymentMethods
            )
        }
    }

    private func didTapToStartNewMonthlyDonation() {
        guard let monthlyPaymentRequest = state.monthly?.paymentRequest else {
            owsFail("[Donations] Cannot start monthly donation. This should be prevented in the UI")
        }

        presentChoosePaymentMethodSheet(
            amount: monthlyPaymentRequest.amount,
            badge: monthlyPaymentRequest.profileBadge,
            donateMode: .monthly,
            supportedPaymentMethods: monthlyPaymentRequest.supportedPaymentMethods
        )
    }

    private func didConfirmMonthlyDonationUpdate() {
        guard
            let monthly = state.monthly,
            let monthlyPaymentRequest = monthly.paymentRequest,
            let subscriberID = monthly.subscriberID,
            let selectedSubscriptionLevel = monthly.selectedSubscriptionLevel
        else {
            owsFail("[Donations] Cannot update monthly donation. This should be prevented in the UI")
        }

        switch monthly.lastReceiptRedemptionFailure {
        case .none:
            let badgesSnapshot = BadgeThanksSheet.currentProfileBadgesSnapshot()
            DonationViewsUtil.wrapPromiseInProgressView(
                from: self,
                promise: firstly(on: DispatchQueue.sharedUserInitiated) {
                    SubscriptionManagerImpl.updateSubscriptionLevel(
                        for: subscriberID,
                        to: selectedSubscriptionLevel,
                        currencyCode: monthly.selectedCurrencyCode
                    )
                }.then(on: DispatchQueue.sharedUserInitiated) { subscription -> Promise<Void> in
                    DonationViewsUtil.redeemMonthlyReceipts(
                        usingPaymentProcessor: subscription.paymentProcessor,
                        subscriberID: subscriberID,
                        newSubscriptionLevel: selectedSubscriptionLevel,
                        priorSubscriptionLevel: monthly.currentSubscriptionLevel
                    )
                    return DonationViewsUtil.waitForSubscriptionJob()
                }
            ).done(on: DispatchQueue.main) {
                self.didCompleteDonation(
                    badge: selectedSubscriptionLevel.badge,
                    thanksSheetType: .subscription,
                    oldBadgesSnapshot: badgesSnapshot
                )
            }.catch(on: DispatchQueue.main) { [weak self] error in
                self?.didFailDonation(
                    error: error,
                    mode: .monthly,
                    paymentMethod: monthly.previousMonthlySubscriptionPaymentMethod
                )
            }
        default:
            Logger.warn("[Donations] Updating a subscription with a prior known error state. Treating this like a new subscription")
            presentChoosePaymentMethodSheet(
                amount: monthlyPaymentRequest.amount,
                badge: monthlyPaymentRequest.profileBadge,
                donateMode: .monthly,
                supportedPaymentMethods: monthlyPaymentRequest.supportedPaymentMethods
            )
        }
    }

    private func didTapToUpdateMonthlyDonation() {
        guard let monthlyPaymentRequest = state.monthly?.paymentRequest else {
            owsFail("[Donations] Cannot update monthly donation. This should be prevented in the UI")
        }

        let currencyString = DonationUtilities.format(money: monthlyPaymentRequest.amount)
        let title = NSLocalizedString(
            "SUSTAINER_VIEW_UPDATE_SUBSCRIPTION_CONFIRMATION_TITLE",
            comment: "Update Subscription? Action sheet title"
        )
        let message = String(
            format: NSLocalizedString(
                "SUSTAINER_VIEW_UPDATE_SUBSCRIPTION_CONFIRMATION_MESSAGE",
                comment: "Update Subscription? Action sheet message, embeds {{Price}}"
            ),
            currencyString
        )
        let notNow = NSLocalizedString(
            "SUSTAINER_VIEW_SUBSCRIPTION_CONFIRMATION_NOT_NOW",
            comment: "Sustainer view Not Now Action sheet button"
        )

        let actionSheet = ActionSheetController(title: title, message: message)
        actionSheet.addAction(.init(
            title: CommonStrings.continueButton,
            style: .default,
            handler: { [weak self] _ in
                self?.didConfirmMonthlyDonationUpdate()
            }
        ))
        actionSheet.addAction(.init(
            title: notNow,
            style: .cancel,
            handler: nil
        ))

        self.presentActionSheet(actionSheet)
    }

    private func didTapToCancelSubscription() {
        let title = NSLocalizedString(
            "SUSTAINER_VIEW_CANCEL_SUBSCRIPTION_CONFIRMATION_TITLE",
            comment: "Confirm Cancellation? Action sheet title"
        )
        let message = NSLocalizedString(
            "SUSTAINER_VIEW_CANCEL_SUBSCRIPTION_CONFIRMATION_MESSAGE",
            comment: "Confirm Cancellation? Action sheet message"
        )
        let confirm = NSLocalizedString(
            "SUSTAINER_VIEW_CANCEL_SUBSCRIPTION_CONFIRMATION_CONFIRM",
            comment: "Confirm Cancellation? Action sheet confirm button"
        )
        let notNow = NSLocalizedString(
            "SUSTAINER_VIEW_SUBSCRIPTION_CONFIRMATION_NOT_NOW",
            comment: "Sustainer view Not Now Action sheet button"
        )
        let actionSheet = ActionSheetController(title: title, message: message)
        actionSheet.addAction(ActionSheetAction(
            title: confirm,
            style: .default,
            handler: { [weak self] _ in
                self?.didConfirmSubscriptionCancelation()
            }
        ))
        actionSheet.addAction(ActionSheetAction(
            title: notNow,
            style: .cancel,
            handler: nil
        ))
        presentActionSheet(actionSheet)
    }

    private func didConfirmSubscriptionCancelation() {
        guard let subscriberID = state.monthly?.subscriberID else {
            owsFail("[Donations] No subscriber ID to cancel")
        }

        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false) { modal in
            firstly {
                SubscriptionManagerImpl.cancelSubscription(for: subscriberID)
            }.done(on: DispatchQueue.main) { [weak self] in
                modal.dismiss { [weak self] in
                    guard let self = self else { return }
                    self.onFinished(.monthlySubscriptionCancelled(
                        donateSheet: self,
                        toastText: NSLocalizedString(
                            "SUSTAINER_VIEW_SUBSCRIPTION_CANCELLED",
                            comment: "Toast indicating that the subscription has been cancelled"
                        )
                    ))
                }
            }.catch { error in
                modal.dismiss()
                owsFailDebug("[Donations] Failed to cancel subscription \(error)")
            }
        }
    }

    internal func didCompleteDonation(
        badge: ProfileBadge,
        thanksSheetType: BadgeThanksSheet.BadgeType,
        oldBadgesSnapshot: ProfileBadgesSnapshot
    ) {
        onFinished(.completedDonation(
            donateSheet: self,
            badgeThanksSheet: BadgeThanksSheet(
                newBadge: badge,
                newBadgeType: thanksSheetType,
                oldBadgesSnapshot: oldBadgesSnapshot
            )
        ))
    }

    internal func didCancelDonation() {
        // A cancel should not be considered "finishing" donation, since the
        // user may want to try again.
        Logger.info("User canceled donation!")
    }

    internal func didFailDonation(
        error: Error,
        mode: DonateMode,
        paymentMethod: DonationPaymentMethod?
    ) {
        DonationViewsUtil.presentDonationErrorSheet(
            from: self,
            error: error,
            paymentMethod: paymentMethod,
            currentSubscription: {
                switch mode {
                case .oneTime: return nil
                case .monthly: return state.monthly?.currentSubscription
                }
            }()
        )
    }

    // MARK: - Loading data

    private func loadAndUpdateState() {
        switch state.loadState {
        case .loading: return
        default: break
        }

        state = state.loading()

        loadStateWithSneakyTransaction(currentState: state).done { [weak self] newState in
            self?.state = newState
        }
    }

    /// Try to load the data we need and put it into a new state.
    ///
    /// Requests one-time and monthly badges and preset amounts from the
    /// service, prepares badge assets, and loads local state as appropriate.
    private func loadStateWithSneakyTransaction(currentState: State) -> Guarantee<State> {
        typealias DonationConfiguration = SubscriptionManagerImpl.DonationConfiguration

        let (
            subscriberID,
            previousSubscriberCurrencyCode,
            previousSubscriberPaymentMethod,
            lastReceiptRedemptionFailure
        ) = databaseStorage.read {
            (
                SubscriptionManagerImpl.getSubscriberID(transaction: $0),
                SubscriptionManagerImpl.getSubscriberCurrencyCode(transaction: $0),
                SubscriptionManagerImpl.getMostRecentSubscriptionPaymentMethod(transaction: $0),
                SubscriptionManagerImpl.lastReceiptRedemptionFailed(transaction: $0)
            )
        }

        // Start fetching the donation configuration.
        let fetchDonationConfigPromise: Promise<DonationConfiguration> = firstly {
            SubscriptionManagerImpl.fetchDonationConfiguration()
        }.then(on: DispatchQueue.sharedUserInitiated) { donationConfiguration -> Promise<DonationConfiguration> in
            let boostBadge = donationConfiguration.boost.badge
            let subscriptionBadges = donationConfiguration.subscription.levels.map { $0.badge }

            let badgePromises = ([boostBadge] + subscriptionBadges).map {
                Self.profileManager.badgeStore.populateAssetsOnBadge($0)
            }

            return Promise.when(fulfilled: badgePromises).map(on: DispatchQueue.sharedUserInitiated) { donationConfiguration }
        }

        // Start loading the current subscription.
        let loadCurrentSubscriptionPromise: Promise<Subscription?> = DonationViewsUtil.loadCurrentSubscription(
            subscriberID: subscriberID
        )

        return firstly { () -> Promise<(DonationConfiguration, Subscription?)> in
            // Compose the configuration and subscription.
            fetchDonationConfigPromise.then(on: DispatchQueue.sharedUserInitiated) { donationConfiguration in
                loadCurrentSubscriptionPromise.map(on: DispatchQueue.sharedUserInitiated) { subscription in
                    (donationConfiguration, subscription)
                }
            }
        }.then(on: DispatchQueue.sharedUserInitiated) { (configuration, currentSubscription) -> Guarantee<State> in
            let loadedState = currentState.loaded(
                oneTimeConfig: configuration.boost,
                monthlyConfig: configuration.subscription,
                paymentMethodsConfig: configuration.paymentMethods,
                currentMonthlySubscription: currentSubscription,
                subscriberID: subscriberID,
                lastReceiptRedemptionFailure: lastReceiptRedemptionFailure,
                previousMonthlySubscriptionCurrencyCode: previousSubscriberCurrencyCode,
                previousMonthlySubscriptionPaymentMethod: previousSubscriberPaymentMethod,
                locale: Locale.current,
                localNumber: Self.tsAccountManager.localNumber
            )

            return .value(loadedState)
        }.recover(on: DispatchQueue.sharedUserInitiated) { error -> Guarantee<State> in
            Logger.warn("[Donations] \(error)")
            owsFailDebugUnlessNetworkFailure(error)
            return Guarantee.value(currentState.loadFailed())
        }
    }

    // MARK: - Top-level rendering

    private let scrollView = UIScrollView()

    private let stackView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        result.alignment = .fill
        result.spacing = 24
        return result
    }()

    private func render(oldState: State?) {
        renderHeroView(oldState: oldState)
        renderBodyView(oldState: oldState)

        if oldState == nil {
            stackView.removeAllSubviews()
            stackView.addArrangedSubviews([heroView, bodyView])
        }

        view.backgroundColor = backgroundColor
    }

    // MARK: - Hero

    private lazy var avatarView: ConversationAvatarView = DonationViewsUtil.avatarView()

    private lazy var heroView: DonationHeroView = {
        let result = DonationHeroView(avatarView: avatarView)
        result.delegate = self
        return result
    }()

    private func renderHeroView(oldState: State?) {
        let selectedProfileBadge = state.selectedProfileBadge
        let shouldUpdateAvatar: Bool = (
            oldState == nil ||
            oldState?.selectedProfileBadge != selectedProfileBadge
        )
        guard shouldUpdateAvatar else { return }

        heroView.rerender()

        databaseStorage.read { [weak self] transaction in
            self?.avatarView.update(transaction) { config in
                guard let address = self?.tsAccountManager.localAddress(with: transaction) else {
                    return
                }
                config.dataSource = .address(address)
                config.addBadgeIfApplicable = true
                config.fallbackBadge = selectedProfileBadge
            }
        }
    }

    // MARK: - Body

    private lazy var bodyView: UIStackView = Self.commonStack()

    private func renderBodyView(oldState: State?) {
        switch state.loadState {
        case .initializing, .loading, .loadFailed:
            // TODO: We should show a different state if the loading failed.
            renderLoadingBody(oldState: oldState)
        case let .loaded(oneTime, monthly):
            renderLoadedBody(
                oldState: oldState,
                donateMode: state.donateMode,
                oneTime: oneTime,
                monthly: monthly
            )
        }
    }

    private func renderLoadingBody(oldState: State?) {
        let wasPreviouslyLoading: Bool = {
            guard let oldState = oldState else { return false }
            switch oldState.loadState {
            case .initializing, .loading, .loadFailed:
                return true
            case .loaded:
                return false
            }
        }()
        if wasPreviouslyLoading { return }

        bodyView.removeAllSubviews()

        let spinner = loadingSpinnerView()
        bodyView.addArrangedSubview(spinner)
    }

    private func renderLoadedBody(
        oldState: State?,
        donateMode: DonateMode,
        oneTime: State.OneTimeState,
        monthly: State.MonthlyState
    ) {
        switch donateMode {
        case .oneTime:
            renderCurrencyPickerView(
                oldState: oldState,
                selectedCurrencyCode: oneTime.selectedCurrencyCode
            )
            renderOneTime(oldState: oldState, oneTime: oneTime)
        case .monthly:
            renderCurrencyPickerView(
                oldState: oldState,
                selectedCurrencyCode: monthly.selectedCurrencyCode
            )
            renderMonthly(oldState: oldState, monthly: monthly)
        }

        renderDonateModePickerView()

        let wasLoaded: Bool = {
            switch oldState?.loadState {
            case .loaded: return true
            default: return false
            }
        }()
        if !wasLoaded || oldState?.donateMode != state.donateMode {
            var subviews: [UIView] = [currencyPickerContainerView]

            if Self.canMakeNewDonations(forDonateMode: state.donateMode) {
                subviews.append(donateModePickerView)
            }

            switch donateMode {
            case .oneTime:
                subviews.append(oneTimeView)
            case .monthly:
                subviews.append(monthlyView)
            }

            bodyView.removeAllSubviews()
            bodyView.addArrangedSubviews(subviews)

            bodyView.setCustomSpacing(18, after: currencyPickerContainerView)

            // Switching modes causes animations to lose their anchors,
            // so we remove them.
            for subview in stackView.subviews {
                if subview is AnimationView {
                    subview.removeFromSuperview()
                }
            }
        }
    }

    // MARK: - Loading spinner

    private func loadingSpinnerView() -> UIView {
        let result: UIActivityIndicatorView
        if #available(iOS 13, *) {
            result = UIActivityIndicatorView(style: .medium)
        } else {
            result = UIActivityIndicatorView(style: .gray)
        }
        result.startAnimating()
        return result
    }

    // MARK: - Currency picker

    private var currencyPickerContainerView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        result.alignment = .fill
        return result
    }()

    private func renderCurrencyPickerView(
        oldState: State?,
        selectedCurrencyCode: Currency.Code
    ) {
        if
            oldState?.donateMode == state.donateMode,
            oldState?.selectedCurrencyCode == selectedCurrencyCode {
            return
        }

        let button = DonationCurrencyPickerButton(
            currentCurrencyCode: selectedCurrencyCode,
            hasLabel: false
        ) { [weak self] in
            guard let self = self else { return }

            let vc = CurrencyPickerViewController(
                dataSource: StripeCurrencyPickerDataSource(
                    currentCurrencyCode: selectedCurrencyCode,
                    supportedCurrencyCodes: self.state.supportedCurrencyCodes
                )
            ) { [weak self] currencyCode in
                guard let self = self else { return }
                self.state = self.state.selectCurrencyCode(currencyCode)
            }

            self.oneTimeCustomAmountTextField.resignFirstResponder()

            self.navigationController?.pushViewController(vc, animated: true)
        }

        currencyPickerContainerView.removeAllSubviews()
        currencyPickerContainerView.addArrangedSubview(button)
    }

    // MARK: - Donation mode picker

    private lazy var donateModePickerView: UISegmentedControl = {
        let picker = UISegmentedControl()
        picker.insertSegment(
            withTitle: NSLocalizedString(
                "DONATE_SCREEN_ONE_TIME_CHOICE",
                comment: "On the donation screen, you can choose between one-time and monthly donations. This is the text on the picker for one-time donations."
            ),
            at: DonateMode.oneTime.rawValue,
            animated: false
        )
        picker.insertSegment(
            withTitle: NSLocalizedString(
                "DONATE_SCREEN_MONTHLY_CHOICE",
                comment: "On the donation screen, you can choose between one-time and monthly donations. This is the text on the picker for one-time donations."
            ),
            at: DonateMode.monthly.rawValue,
            animated: false
        )
        picker.addTarget(self, action: #selector(didDonateModeChange), for: .valueChanged)
        return picker
    }()

    private func renderDonateModePickerView() {
        donateModePickerView.selectedSegmentIndex = state.donateMode.rawValue
    }

    // MARK: - One-time

    private struct OneTimePresetButton {
        let amount: FiatMoney
        let view: OWSFlatButton
    }

    private var oneTimePresetButtons = [OneTimePresetButton]()

    private lazy var oneTimePresetsView: UIStackView = {
        let result = UIStackView()
        result.axis = .vertical
        result.distribution = .fillEqually
        result.spacing = 20
        return result
    }()

    private lazy var oneTimeCustomAmountTextField: OneTimeDonationCustomAmountTextField = {
        guard let currencyCode = state.oneTime?.selectedCurrencyCode else {
            owsFail("[Donations] In the one-time view without a currency code")
        }

        let field = OneTimeDonationCustomAmountTextField(currencyCode: currencyCode)

        field.placeholder = NSLocalizedString(
            "BOOST_VIEW_CUSTOM_AMOUNT_PLACEHOLDER",
            comment: "Default text for the custom amount field of the boost view."
        )
        field.delegate = self
        field.accessibilityIdentifier = UIView.accessibilityIdentifier(
            in: self,
            name: "custom_amount_text_field"
        )

        field.layer.cornerRadius = Self.cornerRadius
        field.layer.borderWidth = DonationViewsUtil.bubbleBorderWidth
        field.font = .dynamicTypeBodyClamped

        let tap = UITapGestureRecognizer(
            target: self,
            action: #selector(didTapOneTimeCustomAmountTextField)
        )
        field.addGestureRecognizer(tap)

        return field
    }()

    private lazy var oneTimeContinueButton: OWSButton = {
        let button = OWSButton(title: CommonStrings.continueButton) { [weak self] in
            self?.didTapToContinueOneTimeDonation()
        }
        button.dimsWhenHighlighted = true
        button.dimsWhenDisabled = true
        button.layer.cornerRadius = 8
        button.backgroundColor = .ows_accentBlue
        button.titleLabel?.font = UIFont.dynamicTypeBody.semibold()
        button.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)
        return button
    }()

    private lazy var oneTimeView: UIStackView = Self.commonStack()

    private func renderOneTime(oldState: State?, oneTime: State.OneTimeState) {
        renderOneTimePresetsView(oldState: oldState, oneTime: oneTime)
        renderOneTimeCustomAmountTextField(oneTime: oneTime)
        renderOneTimeContinueButton(oneTime: oneTime)

        switch oldState?.loadedDonateMode {
        case .oneTime:
            break
        default:
            oneTimeView.removeAllSubviews()
            oneTimeView.addArrangedSubviews([
                oneTimePresetsView,
                oneTimeCustomAmountTextField,
                oneTimeContinueButton
            ])
        }
    }

    private func initialRenderOfOneTimePresetRows(preset: DonationUtilities.Preset) {
        oneTimePresetsView.removeAllSubviews()

        var oneTimePresetButtons = [OneTimePresetButton]()

        for (rowIndex, amounts) in preset.amounts.chunked(by: 3).enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = UIDevice.current.isIPhone5OrShorter ? 8 : 14

            for (colIndex, amount) in amounts.enumerated() {
                let button = OWSFlatButton()
                button.setPressedBlock { [weak self] in
                    let animationNames = [
                        "boost_smile",
                        "boost_clap",
                        "boost_heart_eyes",
                        "boost_fire",
                        "boost_shock",
                        "boost_rockets"
                    ]
                    let animationIndex = (rowIndex * 3) + colIndex
                    self?.didSelectOneTimeAmount(
                        amount: amount,
                        animationAnchor: button,
                        animationName: animationNames[safe: animationIndex] ?? "boost_fire"
                    )
                }
                button.setBackgroundColors(
                    upColor: DonationViewsUtil.bubbleBackgroundColor,
                    downColor: DonationViewsUtil.bubbleBackgroundColor.withAlphaComponent(0.8)
                )
                button.setTitle(
                    title: DonationUtilities.format(money: amount),
                    font: .regularFont(ofSize: UIDevice.current.isIPhone5OrShorter ? 18 : 20),
                    titleColor: Theme.primaryTextColor
                )
                button.autoSetDimension(.height, toSize: 52, relation: .greaterThanOrEqual)
                button.enableMultilineLabel()
                button.layer.cornerRadius = Self.cornerRadius
                button.clipsToBounds = true
                button.layer.borderWidth = DonationViewsUtil.bubbleBorderWidth

                row.addArrangedSubview(button)

                oneTimePresetButtons.append(.init(amount: amount, view: button))
            }

            oneTimePresetsView.addArrangedSubview(row)
        }

        self.oneTimePresetButtons = oneTimePresetButtons
    }

    private func renderOneTimePresetsView(oldState: State?, oneTime: State.OneTimeState) {
        if oldState?.loadedDonateMode != .oneTime || oldState?.oneTime?.selectedCurrencyCode != oneTime.selectedCurrencyCode {
            guard let preset = oneTime.selectedPreset else {
                owsFail("[Donations] It should be impossible to select a currency code without a preset")
            }
            initialRenderOfOneTimePresetRows(preset: preset)
        }

        let selectedPresetAmount: FiatMoney?
        switch oneTime.selectedAmount {
        case .nothingSelected, .choseCustomAmount:
            selectedPresetAmount = nil
        case let .selectedPreset(amount):
            selectedPresetAmount = amount
        }

        for button in oneTimePresetButtons {
            let selected = button.amount == selectedPresetAmount
            button.view.layer.borderColor = selected ? Self.selectedColor : Self.bubbleBackgroundColor
        }
    }

    private func renderOneTimeCustomAmountTextField(oneTime: State.OneTimeState) {
        switch oneTime.selectedAmount {
        case .nothingSelected, .selectedPreset:
            oneTimeCustomAmountTextField.text = nil
            oneTimeCustomAmountTextField.resignFirstResponder()
            oneTimeCustomAmountTextField.layer.borderColor = Self.bubbleBackgroundColor
        case let .choseCustomAmount(amount):
            oneTimeCustomAmountTextField.setCurrencyCode(amount.currencyCode)
            oneTimeCustomAmountTextField.layer.borderColor = Self.selectedColor
            scrollView.scrollIntoView(subview: oneTimeCustomAmountTextField)
        }

        oneTimeCustomAmountTextField.textColor = Theme.primaryTextColor
        oneTimeCustomAmountTextField.backgroundColor = DonationViewsUtil.bubbleBackgroundColor
    }

    private func renderOneTimeContinueButton(oneTime: State.OneTimeState) {
        oneTimeContinueButton.isEnabled = {
            switch oneTime.selectedAmount {
            case .nothingSelected:
                return false
            case .selectedPreset:
                return true
            case let .choseCustomAmount(amount):
                return amount.value > 0
            }
        }()
    }

    // MARK: - Monthly

    private var monthlySubscriptionLevelViews = [MonthlySubscriptionLevelView]()

    private lazy var monthlySubscriptionLevelsView: UIStackView = {
        let result = Self.commonStack()
        result.spacing = 10
        return result
    }()

    private lazy var monthlyButtonsView: UIStackView = {
        let result = Self.commonStack()
        result.spacing = 10
        return result
    }()

    private lazy var monthlyView: UIStackView = Self.commonStack()

    private func renderMonthly(oldState: State?, monthly: State.MonthlyState) {
        renderMonthlySubscriptionLevelsView(oldState: state, monthly: monthly)
        renderMonthlyButtonsView(monthly: monthly)

        switch oldState?.loadedDonateMode {
        case .monthly:
            break
        default:
            monthlyView.removeAllSubviews()
            monthlyView.addArrangedSubviews([
                monthlySubscriptionLevelsView,
                monthlyButtonsView
            ])
        }
    }

    private func initialRenderOfMonthlySubscriptionLevelViews(monthly: State.MonthlyState) {
        monthlySubscriptionLevelsView.removeAllSubviews()

        let animationNames = ["boost_fire", "boost_shock", "boost_rockets"]
        monthlySubscriptionLevelViews = monthly.subscriptionLevels
            .enumerated()
            .map { (index, subscriptionLevel) in
                MonthlySubscriptionLevelView(
                    subscriptionLevel: subscriptionLevel,
                    animationName: animationNames[safe: index] ?? "boost_fire"
                )
            }

        for view in monthlySubscriptionLevelViews {
            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(didTapMonthlySubscriptionLevelView)
            )
            view.addGestureRecognizer(tap)
            monthlySubscriptionLevelsView.addArrangedSubview(view)
        }
    }

    private func renderMonthlySubscriptionLevelsView(oldState: State?, monthly: State.MonthlyState) {
        let renderedSubscriptionLevels = monthlySubscriptionLevelViews.map(\.subscriptionLevel)
        if oldState?.monthly?.subscriptionLevels != renderedSubscriptionLevels {
            initialRenderOfMonthlySubscriptionLevelViews(monthly: monthly)
        }

        for subscriptionLevelView in monthlySubscriptionLevelViews {
            subscriptionLevelView.render(
                currencyCode: monthly.selectedCurrencyCode,
                currentSubscription: monthly.currentSubscription,
                selectedSubscriptionLevel: monthly.selectedSubscriptionLevel
            )
        }
    }

    private func renderMonthlyButtonsView(monthly: State.MonthlyState) {
        var buttons = [OWSButton]()

        if
            let currentSubscription = monthly.currentSubscription,
            currentSubscription.active
        {
            if Self.canMakeNewDonations(forDonateMode: .monthly) {
                let updateTitle = NSLocalizedString(
                    "DONATE_SCREEN_UPDATE_MONTHLY_SUBSCRIPTION_BUTTON",
                    comment: "On the donation screen, if you already have a subscription, you'll see a button to update your subscription. This is the text on that button."
                )
                let updateButton = OWSButton(title: updateTitle) { [weak self] in
                    self?.didTapToUpdateMonthlyDonation()
                }
                updateButton.backgroundColor = .ows_accentBlue
                updateButton.titleLabel?.font = UIFont.dynamicTypeBody.semibold()
                updateButton.isEnabled = {
                    if currentSubscription.amount.currencyCode != monthly.selectedCurrencyCode {
                        return true
                    }
                    if
                        let selectedSubscriptionLevel = monthly.selectedSubscriptionLevel,
                        currentSubscription.level != selectedSubscriptionLevel.level {
                        return true
                    }
                    return false
                }()
                buttons.append(updateButton)
            }

            let cancelTitle = NSLocalizedString(
                "SUSTAINER_VIEW_CANCEL_SUBSCRIPTION",
                comment: "Sustainer view Cancel Subscription button title"
            )
            let cancelButton = OWSButton(title: cancelTitle) { [weak self] in
                self?.didTapToCancelSubscription()
            }
            cancelButton.setTitleColor(Theme.accentBlueColor, for: .normal)
            cancelButton.dimsWhenHighlighted = true
            buttons.append(cancelButton)
        } else {
            let continueButton = OWSButton(title: CommonStrings.continueButton) { [weak self] in
                self?.didTapToStartNewMonthlyDonation()
            }
            continueButton.layer.cornerRadius = 8
            continueButton.backgroundColor = .ows_accentBlue
            continueButton.titleLabel?.font = UIFont.dynamicTypeBody.semibold()

            buttons.append(continueButton)
        }

        for button in buttons {
            button.dimsWhenHighlighted = true
            button.dimsWhenDisabled = true
            button.layer.cornerRadius = 8
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.textAlignment = .center
            button.autoSetDimension(.height, toSize: 48, relation: .greaterThanOrEqual)
        }

        monthlyButtonsView.removeAllSubviews()
        monthlyButtonsView.addArrangedSubviews(buttons)
    }
}

// MARK: - Donation hero delegate

extension DonateViewController: DonationHeroViewDelegate {
    func present(readMoreSheet: DonationReadMoreSheetViewController) {
        present(readMoreSheet, animated: true)
    }
}

// MARK: - One-Time donation custom amount field delegate

extension DonateViewController: OneTimeDonationCustomAmountTextFieldDelegate {
    func oneTimeDonationCustomAmountTextFieldStateDidChange(_ textField: OneTimeDonationCustomAmountTextField) {
        self.state = self.state.selectOneTimeAmount(.choseCustomAmount(amount: textField.amount))
    }
}

// MARK: - UIScrollView

fileprivate extension UIScrollView {
    /// Scroll a subview into view.
    ///
    /// Only meant for use on this screen. Your mileage may vary if used elsewhere.
    func scrollIntoView(subview: UIView) {
        guard let superview = subview.superview else { return }

        let currentVisibleTop = contentOffset.y
        let currentVisibleBottom = currentVisibleTop + bounds.height

        let subviewTop = superview.convert(subview.frame.topLeft, to: self).y
        let subviewBottom = superview.convert(subview.frame.bottomLeft, to: self).y

        let newY: CGFloat
        if subviewTop < currentVisibleTop {
            newY = subviewTop
        } else if subviewBottom > currentVisibleBottom {
            newY = subviewBottom - bounds.height
        } else {
            return
        }

        setContentOffset(.init(x: contentOffset.x, y: newY), animated: true)
    }
}
