//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

private enum OpenableUrl {
    case signalMe(URL)
    case stickerPack(StickerPackInfo)
    case groupInvite(URL)
    case signalProxy(URL)
    case linkDevice(DeviceProvisioningURL)
}

class UrlOpener {
    private let tsAccountManager: TSAccountManager

    init(tsAccountManager: TSAccountManager) {
        self.tsAccountManager = tsAccountManager
    }

    // MARK: - Parsing URLs

    struct ParsedUrl {
        fileprivate let openableUrl: OpenableUrl
    }

    static func parseUrl(_ url: URL) -> ParsedUrl? {
        guard let openableUrl = parseOpenableUrl(url) else {
            return nil
        }
        return ParsedUrl(openableUrl: openableUrl)
    }

    private static func parseOpenableUrl(_ url: URL) -> OpenableUrl? {
        if SignalMe.isPossibleUrl(url) {
            return .signalMe(url)
        }
        if StickerPackInfo.isStickerPackShare(url), let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) {
            return .stickerPack(stickerPackInfo)
        }
        if let stickerPackInfo = parseSgnlAddStickersUrl(url) {
            return .stickerPack(stickerPackInfo)
        }
        if GroupManager.isPossibleGroupInviteLink(url) {
            return .groupInvite(url)
        }
        if SignalProxy.isValidProxyLink(url) {
            return .signalProxy(url)
        }
        if let deviceProvisiongUrl = parseSgnlLinkDeviceUrl(url) {
            return .linkDevice(deviceProvisiongUrl)
        }
        Logger.verbose("Invalid URL: \(url)")
        owsFailDebug("Couldn't parse URL")
        return nil
    }

    private static func parseSgnlAddStickersUrl(_ url: URL) -> StickerPackInfo? {
        guard
            let components = URLComponents(string: url.absoluteString),
            components.scheme == kURLSchemeSGNLKey,
            components.host?.hasPrefix("addstickers") == true,
            let queryItems = components.queryItems
        else {
            return nil
        }
        var packIdHex: String?
        var packKeyHex: String?
        for queryItem in queryItems {
            switch queryItem.name {
            case "pack_id":
                owsAssertDebug(packIdHex == nil)
                packIdHex = queryItem.value
            case "pack_key":
                owsAssertDebug(packKeyHex == nil)
                packKeyHex = queryItem.value
            default:
                Logger.warn("Unknown query item in sticker pack url")
            }
        }
        return StickerPackInfo.parse(packIdHex: packIdHex, packKeyHex: packKeyHex)
    }

    private static func parseSgnlLinkDeviceUrl(_ url: URL) -> DeviceProvisioningURL? {
        guard url.scheme == kURLSchemeSGNLKey, url.host?.hasPrefix(kURLHostLinkDevicePrefix) == true else {
            return nil
        }
        return DeviceProvisioningURL(urlString: url.absoluteString)
    }

    // MARK: - Opening URLs

    func openUrl(_ parsedUrl: ParsedUrl, in window: UIWindow) {
        guard tsAccountManager.isRegistered else {
            return owsFailDebug("Ignoring URL; not registered.")
        }
        guard let rootViewController = window.rootViewController else {
            return owsFailDebug("Ignoring URL; no root view controller.")
        }
        if rootViewController.presentedViewController != nil {
            rootViewController.dismiss(animated: false, completion: {
                self.openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
            })
        } else {
            openUrlAfterDismissing(parsedUrl.openableUrl, rootViewController: rootViewController)
        }
    }

    private func openUrlAfterDismissing(_ openableUrl: OpenableUrl, rootViewController: UIViewController) {
        switch openableUrl {
        case .signalMe(let url):
            SignalMe.openChat(url: url, fromViewController: rootViewController)

        case .stickerPack(let stickerPackInfo):
            let stickerPackViewController = StickerPackViewController(stickerPackInfo: stickerPackInfo)
            stickerPackViewController.present(from: rootViewController, animated: false)

        case .groupInvite(let url):
            GroupInviteLinksUI.openGroupInviteLink(url, fromViewController: rootViewController)

        case .signalProxy(let url):
            rootViewController.present(ProxyLinkSheetViewController(url: url)!, animated: true)

        case .linkDevice(let deviceProvisioningURL):
            guard tsAccountManager.isPrimaryDevice else {
                return owsFailDebug("Ignoring URL; not primary device.")
            }
            let linkedDevicesViewController = LinkedDevicesTableViewController()
            let linkDeviceViewController = OWSLinkDeviceViewController()
            linkDeviceViewController.delegate = linkedDevicesViewController

            let navigationController = AppSettingsViewController.inModalNavigationController()
            var viewControllers = navigationController.viewControllers
            viewControllers.append(linkedDevicesViewController)
            viewControllers.append(linkDeviceViewController)
            navigationController.setViewControllers(viewControllers, animated: false)

            rootViewController.presentFormSheet(navigationController, animated: false) {
                linkDeviceViewController.confirmProvisioning(with: deviceProvisioningURL)
            }
        }
    }
}
