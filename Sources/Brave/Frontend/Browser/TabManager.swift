/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import WebKit
import Storage
import Shared
import BraveShared
import Data
import CoreData
import BraveCore
import BraveWallet
import Favicon
import os.log
import Growth

protocol TabManagerDelegate: AnyObject {
  func tabManager(_ tabManager: TabManager, didSelectedTabChange selected: Tab?, previous: Tab?)
  func tabManager(_ tabManager: TabManager, willAddTab tab: Tab)
  func tabManager(_ tabManager: TabManager, didAddTab tab: Tab)
  func tabManager(_ tabManager: TabManager, willRemoveTab tab: Tab)
  func tabManager(_ tabManager: TabManager, didRemoveTab tab: Tab)

  func tabManagerDidRestoreTabs(_ tabManager: TabManager)
  func tabManagerDidAddTabs(_ tabManager: TabManager)
  func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?)
}

protocol TabManagerStateDelegate: AnyObject {
  func tabManagerWillStoreTabs(_ tabs: [Tab])
}

// We can't use a WeakList here because this is a protocol.
class WeakTabManagerDelegate {
  weak var value: TabManagerDelegate?

  init(value: TabManagerDelegate) {
    self.value = value
  }

  func get() -> TabManagerDelegate? {
    return value
  }
}

// TabManager must extend NSObjectProtocol in order to implement WKNavigationDelegate
class TabManager: NSObject {
  fileprivate var delegates = [WeakTabManagerDelegate]()
  fileprivate let tabEventHandlers: [TabEventHandler]
  weak var stateDelegate: TabManagerStateDelegate?
  
  /// Internal url to access the new tab page.
  private let ntpInteralURL = URL(string: "\(InternalURL.baseUrl)/\(AboutHomeHandler.path)#panel=0")!

  func addDelegate(_ delegate: TabManagerDelegate) {
    assert(Thread.isMainThread)
    delegates.append(WeakTabManagerDelegate(value: delegate))
  }

  func removeDelegate(_ delegate: TabManagerDelegate) {
    assert(Thread.isMainThread)
    for i in 0..<delegates.count {
      let del = delegates[i]
      if delegate === del.get() || del.get() == nil {
        delegates.remove(at: i)
        return
      }
    }
  }

  private(set) var allTabs = [Tab]()
  private var _selectedIndex = -1
  private let navDelegate: TabManagerNavDelegate
  private(set) var isRestoring = false

  // A WKWebViewConfiguration used for normal tabs
  lazy fileprivate var configuration: WKWebViewConfiguration = {
    return TabManager.getNewConfiguration()
  }()

  fileprivate let imageStore: DiskImageStore?

  fileprivate let prefs: Prefs
  var selectedIndex: Int {
    return _selectedIndex
  }
  var normalTabSelectedIndex: Int = 0
  var tempTabs: [Tab]?
  private weak var rewards: BraveRewards?
  private weak var tabGeneratorAPI: BraveTabGeneratorAPI?
  var makeWalletEthProvider: ((Tab) -> (BraveWalletEthereumProvider, js: String)?)?
  var makeWalletSolProvider: ((Tab) -> (BraveWalletSolanaProvider, jsScripts: [BraveWalletProviderScriptKey: String])?)?
  private var domainFrc = Domain.frc()
  private let syncedTabsQueue = DispatchQueue(label: "synced-tabs-queue")
  private var syncTabsTask: DispatchWorkItem?
  private var metricsHeartbeat: Timer?
  
  /// The property returning only existing tab is NTP for current mode
  var isBrowserEmptyForCurrentMode: Bool {
    get {
      guard tabsForCurrentMode.count == 1,
            let tabURL = tabsForCurrentMode.first?.url,
            InternalURL(tabURL)?.isAboutHomeURL == true else {
        return false
      }
      
      return true
    }
  }

  init(prefs: Prefs, imageStore: DiskImageStore?, rewards: BraveRewards?, tabGeneratorAPI: BraveTabGeneratorAPI?) {
    assert(Thread.isMainThread)

    self.prefs = prefs
    self.navDelegate = TabManagerNavDelegate()
    self.imageStore = imageStore
    self.rewards = rewards
    self.tabGeneratorAPI = tabGeneratorAPI
    self.tabEventHandlers = TabEventHandlers.create(with: prefs)
    super.init()

    self.navDelegate.tabManager = self
    addNavigationDelegate(self)

    Preferences.Shields.blockImages.observe(from: self)
    Preferences.General.blockPopups.observe(from: self)
    Preferences.General.nightModeEnabled.observe(from: self)
    
    domainFrc.delegate = self
    do {
      try domainFrc.performFetch()
    } catch {
      Logger.module.error("Failed to perform fetch of Domains for observing dapps permission changes: \(error.localizedDescription, privacy: .public)")
    }
    
    // Initially fired and set up after tabs are restored
    metricsHeartbeat = Timer(timeInterval: 5.minutes, repeats: true, block: { [weak self] _ in
      self?.recordTabCountP3A()
    })
  }
  
  deinit {
    syncTabsTask?.cancel()
  }

  func addNavigationDelegate(_ delegate: WKNavigationDelegate) {
    assert(Thread.isMainThread)

    self.navDelegate.insert(delegate)
  }

  var count: Int {
    assert(Thread.isMainThread)

    return allTabs.count
  }

  var selectedTab: Tab? {
    assert(Thread.isMainThread)
    if !(0..<count ~= _selectedIndex) {
      return nil
    }

    return allTabs[_selectedIndex]
  }

  subscript(index: Int) -> Tab? {
    assert(Thread.isMainThread)

    if index >= allTabs.count {
      return nil
    }
    return allTabs[index]
  }

  subscript(webView: WKWebView) -> Tab? {
    assert(Thread.isMainThread)

    for tab in allTabs where tab.webView === webView {
      return tab
    }

    return nil
  }

  var currentDisplayedIndex: Int? {
    assert(Thread.isMainThread)

    guard let selectedTab = self.selectedTab else {
      return nil
    }

    return tabsForCurrentMode.firstIndex(of: selectedTab)
  }

  // What the users sees displayed based on current private browsing mode
  var tabsForCurrentMode: [Tab] {
    let tabType: TabType = PrivateBrowsingManager.shared.isPrivateBrowsing ? .private : .regular
    return tabs(withType: tabType)
  }

  var openedWebsitesCount: Int {
    tabsForCurrentMode.filter {
      if let url = $0.url {
        return url.isWebPage() && !(InternalURL(url)?.isAboutHomeURL ?? false)
      }
      return false
    }.count
  }

  func tabsForCurrentMode(for query: String? = nil) -> [Tab] {
    if let query = query {
      let tabType: TabType = PrivateBrowsingManager.shared.isPrivateBrowsing ? .private : .regular
      return tabs(withType: tabType, query: query)
    } else {
      return tabsForCurrentMode
    }
  }

  private func tabs(withType type: TabType, query: String? = nil) -> [Tab] {
    assert(Thread.isMainThread)

    let allTabs = allTabs.filter { $0.type == type }

    if let query = query, !query.isEmpty {
      // Display title is the only data that will be present on every situation
      return allTabs.filter { $0.displayTitle.lowercased().contains(query) || ($0.url?.baseDomain?.contains(query) ?? false) }
    } else {
      return allTabs
    }
  }
  
  /// Function for adding local tabs as synced sessions
  /// This is used when open tabs toggle is enabled in sync settings and browser constructor
  func addRegularTabsToSyncChain() {
    let regularTabs = tabs(withType: .regular)

    syncTabsTask?.cancel()

    syncTabsTask = DispatchWorkItem {
        guard let task = self.syncTabsTask, !task.isCancelled else {
          return
        }
        
        for tab in regularTabs {
          if let url = tab.fetchedURL, !tab.type.isPrivate, !url.isLocal, !InternalURL.isValid(url: url), !url.isReaderModeURL {
            tab.addTabInfoToSyncedSessions(url: url, displayTitle: tab.displayTitle)
          }
        }
    }
        
    if let task = self.syncTabsTask {
      DispatchQueue.main.async(execute: task)
    }
  }

  private class func getNewConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.processPool = WKProcessPool()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = !Preferences.General.blockPopups.value

    // Dev note: Do NOT add `.link` to the list, it breaks interstitial pages
    // and pages that don't want the URL highlighted!
    configuration.dataDetectorTypes = [.phoneNumber]

    return configuration
  }

  func resetConfiguration() {
    configuration = TabManager.getNewConfiguration()
  }

  func reset() {
    resetConfiguration()
    allTabs.filter({ $0.webView != nil }).forEach({
      $0.resetWebView(config: configuration)
    })
  }

  func clearTabHistory(_ completion: (() -> Void)? = nil) {
    allTabs.filter({ $0.webView != nil }).forEach({
      $0.clearHistory(config: configuration)
    })

    completion?()
  }

  func reloadSelectedTab() {
    let tab = selectedTab
    _selectedIndex = -1
    selectTab(tab)
    if let url = selectedTab?.url {
      selectedTab?.loadRequest(PrivilegedRequest(url: url) as URLRequest)
    }
  }

  func selectTab(_ tab: Tab?, previous: Tab? = nil) {
    assert(Thread.isMainThread)
    let previous = previous ?? selectedTab

    if previous === tab {
      return
    }
    // Convert the global mode to private if opening private tab from normal tab/ history/bookmark.
    if selectedTab?.isPrivate == false && tab?.isPrivate == true {
      PrivateBrowsingManager.shared.isPrivateBrowsing = true
    }
    // Make sure to wipe the private tabs if the user has the pref turned on
    if !TabType.of(tab).isPrivate {
      removeAllPrivateTabs()
    }

    if let tab = tab {
      _selectedIndex = allTabs.firstIndex(of: tab) ?? -1
    } else {
      _selectedIndex = -1
    }

    preserveScreenshots()

    if let t = selectedTab, t.webView == nil {
      selectedTab?.createWebview()
      restoreTab(t)
    }

    guard tab === selectedTab else {
      Logger.module.error("Expected tab (\(tab?.url?.absoluteString ?? "nil")) is not selected. Selected index: \(self.selectedIndex)")
      return
    }

    if let tabId = tab?.id {
      TabMO.selectTabAndDeselectOthers(selectedTabId: tabId)
    }

    UIImpactFeedbackGenerator(style: .light).bzzt()
    selectedTab?.createWebview()
    selectedTab?.lastExecutedTime = Date.now()

    delegates.forEach { $0.get()?.tabManager(self, didSelectedTabChange: tab, previous: previous) }
    if let tab = previous {
      TabEvent.post(.didLoseFocus, for: tab)
    }
    if let tab = selectedTab {
      TabEvent.post(.didGainFocus, for: tab)
    }

    if let tabID = tab?.id {
      TabMO.touch(tabID: tabID)
    }

    guard let newSelectedTab = tab, let previousTab = previous, let newTabUrl = newSelectedTab.url, let previousTabUrl = previousTab.url else { return }

    if !PrivateBrowsingManager.shared.isPrivateBrowsing {
      if previousTab.displayFavicon == nil {
        adsRewardsLog.warning("No favicon found in \(previousTab) to report to rewards panel")
      }
      rewards?.reportTabUpdated(
        tab: previousTab, url: previousTabUrl, isSelected: false,
        isPrivate: previousTab.isPrivate)

      if newSelectedTab.displayFavicon == nil && !newTabUrl.isLocal {
        adsRewardsLog.warning("No favicon found in \(newSelectedTab) to report to rewards panel")
      }
      rewards?.reportTabUpdated(
        tab: newSelectedTab, url: newTabUrl, isSelected: true,
        isPrivate: newSelectedTab.isPrivate)
    }
  }

  // Called by other classes to signal that they are entering/exiting private mode
  // This is called by TabTrayVC when the private mode button is pressed and BEFORE we've switched to the new mode
  // we only want to remove all private tabs when leaving PBM and not when entering.
  func willSwitchTabMode(leavingPBM: Bool) {
    if leavingPBM {
      removeAllPrivateTabs()
    }
  }

  /// Called to turn selectedIndex back to -1
  func resetSelectedIndex() {
    _selectedIndex = -1
  }

  func expireSnackbars() {
    assert(Thread.isMainThread)

    for tab in allTabs {
      tab.expireSnackbars()
    }
  }

  func addPopupForParentTab(_ parentTab: Tab, configuration: WKWebViewConfiguration) -> Tab {
    let popup = Tab(configuration: configuration, type: parentTab.type, tabGeneratorAPI: tabGeneratorAPI)
    configureTab(popup, request: nil, afterTab: parentTab, flushToDisk: true, zombie: false, isPopup: true)

    // Wait momentarily before selecting the new tab, otherwise the parent tab
    // may be unable to set `window.location` on the popup immediately after
    // calling `window.open("")`.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
      self.selectTab(popup)
    }

    return popup
  }

  @discardableResult
  func addTabAndSelect(_ request: URLRequest! = nil, configuration: WKWebViewConfiguration! = nil, afterTab: Tab? = nil, isPrivate: Bool) -> Tab {
    let tab = addTab(request, configuration: configuration, afterTab: afterTab, isPrivate: isPrivate)
    selectTab(tab)
    return tab
  }

  func addTabsForURLs(_ urls: [URL], zombie: Bool, isPrivate: Bool = false) {
    assert(Thread.isMainThread)

    if urls.isEmpty {
      return
    }
    // When bulk adding tabs don't notify delegates until we are done
    self.isRestoring = true
    var tab: Tab!
    for url in urls {
      tab = self.addTab(URLRequest(url: url), flushToDisk: false, zombie: zombie, isPrivate: isPrivate)
    }
    // Select the most recent.
    self.selectTab(tab)
    self.isRestoring = false
    // Okay now notify that we bulk-loaded so we can adjust counts and animate changes.
    delegates.forEach { $0.get()?.tabManagerDidAddTabs(self) }
  }

  @discardableResult
  func addTab(_ request: URLRequest? = nil, configuration: WKWebViewConfiguration? = nil, afterTab: Tab? = nil, flushToDisk: Bool = true, zombie: Bool = false, id: String? = nil, isPrivate: Bool) -> Tab {
    assert(Thread.isMainThread)

    // Take the given configuration. Or if it was nil, take our default configuration for the current browsing mode.
    let configuration: WKWebViewConfiguration = configuration ?? self.configuration

    let type: TabType = isPrivate ? .private : .regular
    let tab = Tab(configuration: configuration, type: type, tabGeneratorAPI: tabGeneratorAPI)

    configureTab(tab, request: request, afterTab: afterTab, flushToDisk: flushToDisk, zombie: zombie, id: id)
    return tab
  }

  func moveTab(_ tab: Tab, toIndex visibleToIndex: Int) {
    assert(Thread.isMainThread)

    let currentTabs = tabs(withType: tab.type)

    let toTab = currentTabs[visibleToIndex]

    guard let fromIndex = allTabs.firstIndex(of: tab), let toIndex = allTabs.firstIndex(of: toTab) else {
      return
    }

    // Make sure to save the selected tab before updating the tabs list
    let previouslySelectedTab = selectedTab

    let tab = allTabs.remove(at: fromIndex)
    allTabs.insert(tab, at: toIndex)

    if let previouslySelectedTab = previouslySelectedTab, let previousSelectedIndex = allTabs.firstIndex(of: previouslySelectedTab) {
      _selectedIndex = previousSelectedIndex
    }

    saveTabOrder()
  }

  private func saveTabOrder() {
    if PrivateBrowsingManager.shared.isPrivateBrowsing { return }
    let allTabIds = allTabs.compactMap { $0.id }
    TabMO.saveTabOrder(tabIds: allTabIds)
  }

  func configureTab(_ tab: Tab, request: URLRequest?, afterTab parent: Tab? = nil, flushToDisk: Bool, zombie: Bool, id: String? = nil, isPopup: Bool = false) {
    assert(Thread.isMainThread)

    let isPrivate = tab.type == .private
    if isPrivate {
      // Creating random tab id for private mode, as we don't want to save to database.
      tab.id = UUID().uuidString
    } else {
      tab.id = id ?? TabMO.create()
      
      if let (provider, js) = makeWalletEthProvider?(tab) {
        let providerJS = """
        window.__firefox__.execute(function($, $Object) {
          if (window.isSecureContext) {
            \(js)
          }
        });
        """
        
        tab.walletEthProvider = provider
        tab.walletEthProvider?.`init`(tab)
        tab.walletEthProviderScript = WKUserScript(source: providerJS,
                                                   injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true,
                                                   in: EthereumProviderScriptHandler.scriptSandbox)
      }
      if let (provider, jsScripts) = makeWalletSolProvider?(tab) {
        tab.walletSolProvider = provider
        tab.walletSolProvider?.`init`(tab)
        tab.walletSolProviderScripts = jsScripts
      }
    }
    
    delegates.forEach { $0.get()?.tabManager(self, willAddTab: tab) }

    if parent == nil || parent?.type != tab.type {
      allTabs.append(tab)
    } else if let parent = parent, var insertIndex = allTabs.firstIndex(of: parent) {
      insertIndex += 1
      while insertIndex < allTabs.count && allTabs[insertIndex].isDescendentOf(parent) {
        insertIndex += 1
      }
      tab.parent = parent
      allTabs.insert(tab, at: insertIndex)
    }

    delegates.forEach { $0.get()?.tabManager(self, didAddTab: tab) }

    if !zombie {
      tab.createWebview()
    }
    tab.navigationDelegate = self.navDelegate

    if let request = request {
      tab.loadRequest(request)
    } else if !isPopup {
      
      tab.loadRequest(PrivilegedRequest(url: ntpInteralURL) as URLRequest)
      tab.url = ntpInteralURL
    }

    // Ignore on restore.
    if flushToDisk && !zombie && !isPrivate {
      saveTab(tab, saveOrder: true)
    }
    
    // When the state of the page changes, we debounce a call to save the screenshots and tab information
    // This fixes pages that have dynamic URL via changing history
    // as well as regular pages that load DOM normally.
    tab.onPageReadyStateChanged = { [weak tab] state in
      guard let tab = tab else { return }
      tab.webStateDebounceTimer?.invalidate()
      tab.webStateDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self, weak tab] _ in
        guard let self = self, let tab = tab else { return }
        tab.webStateDebounceTimer?.invalidate()
        
        if state == .complete || state == .loaded || state == .pushstate || state == .popstate || state == .replacestate {
          // Saving Tab Private Mode - not supported yet.
          if !tab.isPrivate {
            self.preserveScreenshots()
            self.saveTab(tab)
          }
        }
      }
    }
  }

  func indexOfWebView(_ webView: WKWebView) -> UInt? {
    objc_sync_enter(self); defer { objc_sync_exit(self) }

    var count = UInt(0)
    for tab in allTabs {
      if tab.webView === webView {
        return count
      }
      count = count + 1
    }

    return nil
  }

  func saveTab(_ tab: Tab, saveOrder: Bool = false) {
    if PrivateBrowsingManager.shared.isPrivateBrowsing { return }
    guard let data = savedTabData(tab: tab) else { return }

    TabMO.update(tabData: data)
    if saveOrder {
      saveTabOrder()
    }
  }

  private func savedTabData(tab: Tab) -> SavedTab? {

    guard let webView = tab.webView, let order = indexOfWebView(webView) else { return nil }

    // Ignore session restore data.
    guard let url = tab.url,
      !InternalURL.isValid(url: url),
      !(InternalURL(url)?.isSessionRestore ?? false)
    else { return nil }

    var urls = [URL]()
    var currentPage = 0

    if let currentItem = webView.backForwardList.currentItem {
      // Freshly created web views won't have any history entries at all.
      let backList = webView.backForwardList.backList
      let forwardList = webView.backForwardList.forwardList
      let backListMap = backList.map { $0.url }
      let forwardListMap = forwardList.map { $0.url }
      let currentItem = currentItem.url

      // Business as usual.
      urls = backListMap + [currentItem] + forwardListMap
      currentPage = -forwardList.count
    }
    if let id = TabMO.get(fromId: tab.id)?.syncUUID {
      let displayTitle = tab.displayTitle
      let title = displayTitle != "" ? displayTitle : ""

      let isSelected = selectedTab === tab

      let urls = SessionData.updateSessionURLs(urls: urls).map({ $0.absoluteString })
      let data = SavedTab(
        id: id, title: title, url: url.absoluteString,
        isSelected: isSelected, order: Int16(order),
        screenshot: nil, history: urls,
        historyIndex: Int16(currentPage),
        isPrivate: tab.isPrivate)
      return data
    }

    return nil
  }

  func removeTab(_ tab: Tab) {
    assert(Thread.isMainThread)

    guard let removalIndex = allTabs.firstIndex(where: { $0 === tab }) else {
      Logger.module.debug("Could not find index of tab to remove")
      return
    }

    if tab.isPrivate {
      // Only when ALL tabs are dead, we clean up.
      // This is because other tabs share the same data-store.
      if tabs(withType: .private).count <= 1 {
        removeAllBrowsingDataForTab(tab)

        // After clearing the very last webview from the storage, give it a blank persistent store
        // This is the only way to guarantee that the last reference to the shared persistent store
        // reaches zero and destroys all its data.

        BraveWebView.removeNonPersistentStore()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
      }
    }

    let oldSelectedTab = selectedTab

    delegates.forEach { $0.get()?.tabManager(self, willRemoveTab: tab) }

    // The index of the tab in its respective tab grouping. Used to figure out which tab is next
    var currentTabs = tabs(withType: tab.type)

    var tabIndex: Int = -1
    if let oldTab = oldSelectedTab {
      tabIndex = currentTabs.firstIndex(of: oldTab) ?? -1
    }

    let prevCount = count
    allTabs.remove(at: removalIndex)

    if let tab = TabMO.get(fromId: tab.id) {
      tab.delete()
    }

    currentTabs = tabs(withType: tab.type)

    // Let's select the tab to be selected next.
    if let oldTab = oldSelectedTab, tab !== oldTab {
      // If it wasn't the selected tab we removed, then keep it like that.
      // It might have changed index, so we look it up again.
      _selectedIndex = allTabs.firstIndex(of: oldTab) ?? -1
    } else if let parentTab = tab.parent,
      currentTabs.count > 1,
      let newTab = currentTabs.reduce(
        currentTabs.first, { currentBestTab, tab2 in
          if let tab1 = currentBestTab, let time1 = tab1.lastExecutedTime {
            if let time2 = tab2.lastExecutedTime {
              return time1 <= time2 ? tab2 : tab1
            }
            return tab1
          } else {
            return tab2
          }
        }), parentTab == newTab, tab !== newTab, newTab.lastExecutedTime != nil {
      // We select the most recently visited tab, only if it is also the parent tab of the closed tab.
      _selectedIndex = allTabs.firstIndex(of: newTab) ?? -1
    } else {
      // By now, we've just removed the selected one, and no previously loaded
      // tabs. So let's load the final one in the tab tray.
      if tabIndex == currentTabs.count {
        tabIndex -= 1
      }

      if let currentTab = currentTabs[safe: tabIndex] {
        _selectedIndex = allTabs.firstIndex(of: currentTab) ?? -1
      } else {
        _selectedIndex = -1
      }
    }

    assert(count == prevCount - 1, "Make sure the tab count was actually removed")

    // There's still some time between this and the webView being destroyed. We don't want to pick up any stray events.
    tab.webView?.navigationDelegate = nil

    delegates.forEach { $0.get()?.tabManager(self, didRemoveTab: tab) }
    TabEvent.post(.didClose, for: tab)

    if currentTabs.isEmpty {
      addTab(isPrivate: tab.isPrivate)
    }

    // If the removed tab was selected, find the new tab to select.
    if selectedTab != nil {
      selectTab(selectedTab, previous: oldSelectedTab)
    } else {
      selectTab(allTabs.last, previous: oldSelectedTab)
    }
  }

  /// Removes all private tabs from the manager without notifying delegates.
  private func removeAllPrivateTabs() {
    // reset the selectedTabIndex if we are on a private tab because we will be removing it.
    if TabType.of(selectedTab).isPrivate {
      _selectedIndex = -1
    }

    allTabs.forEach { tab in
      if tab.isPrivate {
        tab.webView?.removeFromSuperview()
        removeAllBrowsingDataForTab(tab)
      }
    }

    BraveWebView.removeNonPersistentStore()

    allTabs = tabs(withType: .regular)
  }

  func removeAllBrowsingDataForTab(_ tab: Tab, completionHandler: @escaping () -> Void = {}) {
    let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
    tab.webView?.configuration.websiteDataStore.removeData(
      ofTypes: dataTypes,
      modifiedSince: Date.distantPast,
      completionHandler: completionHandler)
  }

  func removeTabsWithUndoToast(_ tabs: [Tab]) {
    tempTabs = tabs
    var tabsCopy = tabs

    // Remove the current tab last to prevent switching tabs while removing tabs
    if let selectedTab = selectedTab {
      if let selectedIndex = tabsCopy.firstIndex(of: selectedTab) {
        let removed = tabsCopy.remove(at: selectedIndex)
        removeTabs(tabsCopy)
        removeTab(removed)
      } else {
        removeTabs(tabsCopy)
      }
    }
    for tab in tabs {
      tab.hideContent()
    }
    var toast: ButtonToast?
    if let numberOfTabs = tempTabs?.count, numberOfTabs > 0 {
      toast = ButtonToast(
        labelText: String.localizedStringWithFormat(Strings.tabsDeleteAllUndoTitle, numberOfTabs), buttonText: Strings.tabsDeleteAllUndoAction,
        completion: { buttonPressed in
          if buttonPressed {
            self.undoCloseTabs()
            for delegate in self.delegates {
              delegate.get()?.tabManagerDidAddTabs(self)
            }
          }
          self.eraseUndoCache()
        })
    }

    delegates.forEach { $0.get()?.tabManagerDidRemoveAllTabs(self, toast: toast) }
  }

  func undoCloseTabs() {
    guard let tempTabs = self.tempTabs, !tempTabs.isEmpty else {
      return
    }

    let tabsCopy = tabs(withType: .regular)

    restoreDeletedTabs(tempTabs)
    self.isRestoring = true

    for tab in tempTabs {
      tab.showContent(true)
    }

    let tab = tempTabs.first
    if !TabType.of(tab).isPrivate {
      removeTabs(tabsCopy)
    }
    selectTab(tab)

    self.isRestoring = false
    delegates.forEach { $0.get()?.tabManagerDidRestoreTabs(self) }
    self.tempTabs?.removeAll()
    allTabs.first?.createWebview()
  }

  func eraseUndoCache() {
    tempTabs?.removeAll()
  }

  func removeTabs(_ tabs: [Tab]) {
    for tab in tabs {
      self.removeTab(tab)
    }
  }

  func removeAll() {
    removeTabs(self.allTabs)
  }
  
  func removeAllForCurrentMode() {
    removeTabs(tabsForCurrentMode)
  }

  func getIndex(_ tab: Tab) -> Int? {
    assert(Thread.isMainThread)

    for i in 0..<count where allTabs[i] === tab {
      return i
    }

    assertionFailure("Tab not in tabs list")
    return nil
  }

  func getTabForURL(_ url: URL) -> Tab? {
    assert(Thread.isMainThread)
    
    let tab = allTabs.filter {
      guard let webViewURL = $0.webView?.url else {
        return  false
      }
      
      return webViewURL.schemelessAbsoluteDisplayString == url.schemelessAbsoluteDisplayString
    }.first
    
    return tab
  }
  
  func getTabForID(_ id: String) -> Tab? {
    assert(Thread.isMainThread)

    return allTabs.filter { $0.id == id }.first
  }

  func resetProcessPool() {
    assert(Thread.isMainThread)

    configuration.processPool = WKProcessPool()
  }

  static fileprivate func tabsStateArchivePath() -> String {
    guard let profilePath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier)?.appendingPathComponent("profile.profile").path else {
      let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
      return URL(fileURLWithPath: documentsPath).appendingPathComponent("tabsState.archive").path
    }

    return URL(fileURLWithPath: profilePath).appendingPathComponent("tabsState.archive").path
  }

  static fileprivate func migrateTabsStateArchive() {
    guard let oldPath = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("tabsState.archive").path, FileManager.default.fileExists(atPath: oldPath) else {
      return
    }

    Logger.module.info("Migrating tabsState.archive from ~/Documents to shared container")

    guard let profilePath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier)?.appendingPathComponent("profile.profile").path else {
      Logger.module.error("Unable to get profile path in shared container to move tabsState.archive")
      return
    }

    let newPath = URL(fileURLWithPath: profilePath).appendingPathComponent("tabsState.archive").path

    do {
      try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true, attributes: nil)
      try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)

      Logger.module.info("Migrated tabsState.archive to shared container successfully")
    } catch let error as NSError {
      Logger.module.error("Unable to move tabsState.archive to shared container: \(error.localizedDescription)")
    }
  }

  static func tabArchiveData() -> Data? {
    migrateTabsStateArchive()

    let tabStateArchivePath = tabsStateArchivePath()
    if FileManager.default.fileExists(atPath: tabStateArchivePath) {
      return (try? Data(contentsOf: URL(fileURLWithPath: tabStateArchivePath)))
    } else {
      return nil
    }
  }

  private func preserveScreenshots() {
    assert(Thread.isMainThread)
    if isRestoring { return }

    Task { @MainActor in
      var savedUUIDs = Set<String>()
      
      for tab in allTabs {
        guard let screenshot = tab.screenshot, let screenshotUUID = tab.screenshotUUID else { continue }
        savedUUIDs.insert(screenshotUUID.uuidString)
        try? await imageStore?.put(screenshotUUID.uuidString, image: screenshot)
      }
      
      // Clean up any screenshots that are no longer associated with a tab.
      await imageStore?.clearExcluding(savedUUIDs)
    }
  }

  fileprivate var restoreTabsInternal: Tab? {
    var savedTabs = [TabMO]()

    if let autocloseTime = Preferences.AutoCloseTabsOption(
      rawValue: Preferences.General.autocloseTabs.value)?.timeInterval {
      // To avoid db problems, we first retrieve fresh tabs(on main thread context)
      // then delete old tabs(background thread context)
      savedTabs = TabMO.all(noOlderThan: autocloseTime)
      TabMO.deleteAll(olderThan: autocloseTime)
    } else {
      savedTabs = TabMO.getAll()
    }

    if savedTabs.isEmpty { return nil }

    var tabToSelect: Tab?
    for savedTab in savedTabs {
      guard let urlString = savedTab.url else {
        savedTab.delete()
        continue
      }

      // Provide an empty request to prevent a new tab from loading the home screen
      let tab = addTab(
        nil, configuration: nil, afterTab: nil, flushToDisk: false, zombie: true,
        id: savedTab.syncUUID, isPrivate: false)

      // Since this is a restored tab, reset the URL to be loaded as that will be handled by the SessionRestoreHandler
      tab.url = nil
      let isPrivateBrowsing = PrivateBrowsingManager.shared.isPrivateBrowsing
      if let url = URL(string: urlString) {
        tab.favicon = FaviconFetcher.getIconFromCache(for: url) ?? Favicon.default
        Task { @MainActor in
          tab.favicon = try await FaviconFetcher.loadIcon(url: url, kind: .smallIcon, persistent: !isPrivateBrowsing)
        }
      }

      // Set the UUID for the tab, asynchronously fetch the UIImage, then store
      // the screenshot in the tab as long as long as a newer one hasn't been taken.
      if let screenshotUUID = savedTab.screenshotUUID, let imageStore = imageStore {
        tab.screenshotUUID = UUID(uuidString: screenshotUUID)
        Task { @MainActor in
          let screenshot = try await imageStore.get(screenshotUUID)
          tab.setScreenshot(screenshot, revUUID: false)
        }
      }

      if savedTab.isSelected {
        tabToSelect = tab
      }

      tab.lastTitle = savedTab.title
    }

    if let tabToSelect = tabToSelect ?? tabsForCurrentMode.last {
      // Only tell our delegates that we restored tabs if we actually restored something
      delegates.forEach {
        $0.get()?.tabManagerDidRestoreTabs(self)
      }

      // No tab selection, since this is unfamiliar with launch timings (e.g. compiling blocklists)

      // Must return inside this `if` to potentially return the conditional fallback
      return tabToSelect
    }
    return nil
  }

  func restoreTab(_ tab: Tab) {
    // Tab was created with no active webview or session data. Restore tab data from CD and configure.
    guard let savedTab = TabMO.get(fromId: tab.id) else { return }

    if let history = savedTab.urlHistorySnapshot as? [String], let tabUUID = savedTab.syncUUID, let url = savedTab.url {
      let data = SavedTab(id: tabUUID, title: savedTab.title, url: url, isSelected: savedTab.isSelected, order: savedTab.order, screenshot: nil, history: history, historyIndex: savedTab.urlHistoryCurrentIndex, isPrivate: tab.isPrivate)
      if let webView = tab.webView {
        tab.navigationDelegate = navDelegate
        tab.restore(webView, restorationData: data)
      }
    }
  }

  /// Restores all tabs.
  /// Returns the tab that has to be selected after restoration.
  var restoreAllTabs: Tab {
    defer {
      metricsHeartbeat?.fire()
      RunLoop.current.add(metricsHeartbeat!, forMode: .default)
    }
    
    isRestoring = true
    let tabToSelect = self.restoreTabsInternal
    isRestoring = false

    // Always make sure there is at least one tab.
    let isPrivate = Preferences.Privacy.privateBrowsingOnly.value
    return tabToSelect ?? self.addTab(isPrivate: isPrivate)
  }

  func restoreDeletedTabs(_ savedTabs: [Tab]) {
    isRestoring = true
    for tab in savedTabs {
      allTabs.append(tab)
      tab.navigationDelegate = self.navDelegate
      for delegate in delegates {
        delegate.get()?.tabManager(self, didAddTab: tab)
      }
    }
    isRestoring = false
  }
  
  // MARK: - P3A
  
  private func recordTabCountP3A() {
    // Q7 How many open tabs do you have?
    let count = allTabs.count
    UmaHistogramRecordValueToBucket(
      "Brave.Core.TabCount",
      buckets: [
        .r(0...1),
        .r(2...5),
        .r(6...10),
        .r(11...50),
        .r(51...)
      ],
      value: count
    )
  }
  
  // MARK: - Recently Closed
  
  /// Function used to add the tab information to Recently Closed when it is removed
  /// - Parameter tab: The tab which is removed
  func addTabToRecentlyClosed(_ tab: Tab) {
    if let savedItem = createRecentlyClosedFromActiveTab(tab) {
      RecentlyClosed.insert(savedItem)
    }
  }
  
  /// Function to add all the tabs to recently closed before the list is removef entirely by Close All Tabs
  func addAllTabsToRecentlyClosed() {
    var allRecentlyClosed: [SavedRecentlyClosed] = []
    
    tabs(withType: .regular).forEach {
      if let savedItem = createRecentlyClosedFromActiveTab($0) {
        allRecentlyClosed.append(savedItem)
      }
    }
        
    RecentlyClosed.insertAll(allRecentlyClosed)
  }
  
  /// Function invoked when a Recently Closed item is selected
  /// This function adss a new tab, populates this tab with necessary information
  /// Also executes restore function on this tab to load History Snapshot to teh webview
  /// - Parameter recentlyClosed: Recently Closed item to be processed
  func addAndSelectRecentlyClosed(_ recentlyClosed: RecentlyClosed) {
    guard let url = URL(string: recentlyClosed.url) else {
      return
    }
    
    let tab = addTab(URLRequest(url: url), isPrivate: false)
    guard let webView = tab.webView, let order = indexOfWebView(webView) else { return }

    if let history = recentlyClosed.historyList as? [String], let tabUUID = tab.id {
      let data = SavedTab(
        id: tabUUID,
        title: recentlyClosed.title,
        url: recentlyClosed.url,
        isSelected: false,
        order: Int16(order),
        screenshot: nil,
        history: history,
        historyIndex: recentlyClosed.historyIndex,
        isPrivate: false)
      
      tab.navigationDelegate = navDelegate
      tab.restore(webView, restorationData: data)
    }
    
    selectTab(tab)
  }
  
  /// Function used to auto delete outdated Recently Closed Tabs
  func deleteOutdatedRecentlyClosed() {
    // The time interval to remove Recently Closed 3 days
    let autoRemoveInterval = AppConstants.buildChannel.isPublic ? 30.minutes : 3.days
    
    RecentlyClosed.deleteAll(olderThan: autoRemoveInterval)
  }
  
  /// An internal function to create a RecentlyClosed item from a tab
  /// Also handles the backforward list transfer
  /// - Parameter tab: Tab to be converted to Recently Closed
  /// - Returns: Recently Closed item
  private func createRecentlyClosedFromActiveTab(_ tab: Tab) -> SavedRecentlyClosed? {
    // Private Tabs can not be added to Recently Closed
    if tab.isPrivate {
      return nil
    }
    
    // Fetching the Managed Object using the tab id
    guard let tabID = tab.id,
          let fetchedTab = TabMO.get(fromId: tabID),
          let urlString = fetchedTab.url else {
      return nil
    }
    
    // Gathering History Snaphot from Tab Managed Object
    let urlHistorySnapshot: [String] = fetchedTab.urlHistorySnapshot as? [String] ?? []
    
    let recentlyClosedHistoryList = urlHistorySnapshot.compactMap {
      // Session Restore URLs should be converted into extracted URL
      // before being passed as backforward history
      if let _url = URL(string: $0), let url = InternalURL(_url) {
        return url.extractedUrlParam
      }
      return URL(string: $0)
    }
    
    // NTP should not be passed as Recently Closed item if there are no items in History Snapshot
    if let url = URL(string: urlString), InternalURL(url)?.isAboutHomeURL == true, urlHistorySnapshot.count > 1 {
      return nil
    }
    
    let savedItem = SavedRecentlyClosed(
      url: urlString,
      title: fetchedTab.title,
      historyList: recentlyClosedHistoryList.map({ $0.absoluteString }),
      historyIndex: fetchedTab.urlHistoryCurrentIndex)
    
    return savedItem
  }
}

extension TabManager: WKNavigationDelegate {

  // Note the main frame JSContext (i.e. document, window) is not available yet.
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    if let tab = self[webView] {
      tab.contentBlocker.clearPageStats()
    }
  }

  // The main frame JSContext is available, and DOM parsing has begun.
  // Do not excute JS at this point that requires running prior to DOM parsing.
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // only store changes if this is not an error page
    // as we current handle tab restore as error page redirects then this ensures that we don't
    // call storeChanges unnecessarily on startup

    if let url = webView.url {
      // tab restore uses internal pages,
      // so don't call storeChanges unnecessarily on startup
      if InternalURL(url)?.isSessionRestore == true {
        return
      }

      // Saving Tab Private Mode - not supported yet.
      if let tab = tabForWebView(webView), !tab.isPrivate {
        preserveScreenshots()
        saveTab(tab)
      }
    }
  }

  func tabForWebView(_ webView: WKWebView) -> Tab? {
    objc_sync_enter(self); defer { objc_sync_exit(self) }

    return allTabs.first(where: { $0.webView === webView })
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
  }

  /// Called when the WKWebView's content process has gone away. If this happens for the currently selected tab
  /// then we immediately reload it.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if let tab = selectedTab, tab.webView == webView {
      webView.reload()
    }
  }
}

// MARK: - TabManagerDelegate optional methods.
extension TabManagerDelegate {
  func tabManager(_ tabManager: TabManager, willAddTab tab: Tab) {}
  func tabManager(_ tabManager: TabManager, willRemoveTab tab: Tab) {}
  func tabManagerDidAddTabs(_ tabManager: TabManager) {}
  func tabManagerDidRemoveAllTabs(_ tabManager: TabManager, toast: ButtonToast?) {}
}

extension TabManager: PreferencesObserver {
  func preferencesDidChange(for key: String) {
    switch key {
    case Preferences.General.blockPopups.key:
      let allowPopups = !Preferences.General.blockPopups.value
      // Each tab may have its own configuration, so we should tell each of them in turn.
      allTabs.forEach {
        $0.webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
      }
      // The default tab configurations also need to change.
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
    case Preferences.General.nightModeEnabled.key:
      NightModeScriptHandler.setNightMode(tabManager: self, enabled: Preferences.General.nightModeEnabled.value)
    default:
      break
    }
  }
}

extension TabManager: NSFetchedResultsControllerDelegate {
  func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
    if let domain = anObject as? Domain, let domainURL = domain.url {
      // if `wallet_permittedAccounts` changes on a `Domain` from
      // wallet settings / manage web3 site connections, we need to
      // fire `accountsChanged` event on open tabs for this `Domain`
      let tabsForDomain = self.allTabs.filter { $0.url?.domainURL.absoluteString.caseInsensitiveCompare(domainURL) == .orderedSame }
      tabsForDomain.forEach { tab in
        Task { @MainActor in
          let accounts = await tab.allowedAccountsForCurrentCoin().1
          tab.accountsChangedEvent(Array(accounts))
        }
      }
    }
  }
}
