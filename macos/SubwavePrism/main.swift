import Cocoa
import AVFoundation
import WebKit

private struct NativeStation: Codable {
    let slug: String
    let name: String
    let url: String
    let location: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let startURL = URL(string: "https://prism.gurthyy.xyz/?skin=prism")!
    private let appUserAgentToken = "SubwavePrism/1.0"
    private let stationDefaultsKey = "stationURL"
    private let stationListDefaultsKey = "stations"
    private let defaultStationURL = "https://radio.gurthyy.xyz"
    private var window: NSWindow!
    private var webView: WKWebView!
    private var player: AVPlayer?
    private var playerAsset: AVURLAsset?
    private var currentNativeStreamURL: URL?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupTerminationSignalHandlers()

        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = appUserAgentToken
        configuration.userContentController.addUserScript(nativeAudioBridgeScript())
        configuration.userContentController.add(self, name: "subwaveNative")

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Subwave Prism"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 620)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)

        loadStartURL()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        stopNativePlayback()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopNativePlayback()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopNativePlayback()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "subwaveNative")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopNativePlayback()
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        stopNativePlayback()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "subwaveNative", let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String
        switch type {
        case "play":
            let src = body["src"] as? String
            let volume = body["volume"] as? Double ?? 1
            let muted = body["muted"] as? Bool ?? false
            playNativeStream(src: src, volume: volume, muted: muted)
        case "pause", "stop":
            stopNativePlayback()
        case "volume":
            let volume = body["volume"] as? Double ?? 1
            let muted = body["muted"] as? Bool ?? false
            player?.volume = muted ? 0 : Float(max(0, min(1, volume)))
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    private func showLoadError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Subwave Prism could not load."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            loadStartURL()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func loadStartURL() {
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            guard let self else { return }
            if let defaultUserAgent = result as? String, !defaultUserAgent.contains(self.appUserAgentToken) {
                self.webView.customUserAgent = "\(defaultUserAgent) \(self.appUserAgentToken)"
            }
            self.webView.load(URLRequest(url: self.startURL))
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Station Settings...", action: #selector(showStationSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Subwave Prism", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stopNativePlayback()
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    @objc private func showStationSettings() {
        let alert = NSAlert()
        alert.messageText = "Station"
        alert.informativeText = "Choose a saved station or enter a custom SUB/WAVE station URL."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stations = savedStations()
        let activeURL = stationURL().absoluteString
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        var selectedIndex = 0
        for (index, station) in stations.enumerated() {
            popup.addItem(withTitle: station.location.map { "\(station.name) - \($0)" } ?? station.name)
            popup.item(at: index)?.representedObject = station.url
            if normalizeStationURL(station.url)?.absoluteString == activeURL {
                selectedIndex = index
            }
        }
        popup.addItem(withTitle: "Custom URL...")
        popup.selectItem(at: selectedIndex)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = activeURL

        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 58)
        alert.accessoryView = stack

        if alert.runModal() == .alertFirstButtonReturn {
            let selectedURL = popup.selectedItem?.representedObject as? String
            guard let normalized = normalizeStationURL(selectedURL ?? field.stringValue) else {
                showStationURLError()
                return
            }
            saveStation(normalized)
            stopNativePlayback()
            loadStartURL()
        }
    }

    private func savedStations() -> [NativeStation] {
        let defaults = UserDefaults.standard
        var stations: [NativeStation] = []
        if let data = defaults.data(forKey: stationListDefaultsKey),
           let decoded = try? JSONDecoder().decode([NativeStation].self, from: data) {
            stations = decoded
        }
        let active = stationFromURL(stationURL())
        if !stations.contains(where: { normalizeStationURL($0.url)?.absoluteString == active.url }) {
            stations.insert(active, at: 0)
        }
        return stations
    }

    private func saveStation(_ url: URL) {
        let defaults = UserDefaults.standard
        let station = stationFromURL(url)
        let rest = savedStations().filter { normalizeStationURL($0.url)?.absoluteString != station.url }
        let next = [station] + rest
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: stationListDefaultsKey)
        }
        defaults.set(station.url, forKey: stationDefaultsKey)
    }

    private func stationFromURL(_ url: URL) -> NativeStation {
        let host = url.host ?? "Saved station"
        let slug = "native-\(host.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression))"
        return NativeStation(slug: slug, name: host, url: url.absoluteString, location: "Local")
    }

    private func showStationURLError() {
        let alert = NSAlert()
        alert.messageText = "That station URL does not look valid."
        alert.informativeText = "Use a full station URL like https://radio.gurthyy.xyz."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func stationURL() -> URL {
        if let stored = UserDefaults.standard.string(forKey: stationDefaultsKey),
           let url = normalizeStationURL(stored) {
            return url
        }
        return URL(string: defaultStationURL)!
    }

    private func normalizeStationURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.range(of: "://") == nil ? "https://\(trimmed)" : trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func streamURL(from source: String?) -> URL {
        if let source, let url = URL(string: source), url.scheme != nil {
            return url
        }
        return stationURL().appendingPathComponent("stream.mp3")
    }

    private func playNativeStream(src: String?, volume: Double, muted: Bool) {
        let url = streamURL(from: src)
        if currentNativeStreamURL != url {
            currentNativeStreamURL = url
            let asset = AVURLAsset(
                url: url,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "User-Agent": "\(appUserAgentToken) macOS AVPlayer"
                    ]
                ]
            )
            playerAsset = asset
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        player?.volume = muted ? 0 : Float(max(0, min(1, volume)))
        player?.play()
    }

    private func stopNativePlayback() {
        let item = player?.currentItem
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        item?.cancelPendingSeeks()
        item?.asset.cancelLoading()
        playerAsset?.cancelLoading()
        player = nil
        playerAsset = nil
        currentNativeStreamURL = nil
    }

    private func nativeAudioBridgeScript() -> WKUserScript {
        let station = stationURL()
        let stationName = station.host ?? "Saved station"
        let stationSlug = "native-\(stationName.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression))"
        let stationJSON: [String: Any] = [
            "slug": stationSlug,
            "name": stationName,
            "url": station.absoluteString,
            "location": "Native app"
        ]
        let stationData = try! JSONSerialization.data(withJSONObject: stationJSON)
        let stationJSONString = String(data: stationData, encoding: .utf8)!
        let localStations = savedStations().map { station -> [String: String] in
            var item = [
                "slug": station.slug,
                "name": station.name,
                "url": station.url,
            ]
            if let location = station.location {
                item["location"] = location
            }
            return item
        }
        let localStationsData = try! JSONSerialization.data(withJSONObject: localStations)
        let localStationsJSONString = String(data: localStationsData, encoding: .utf8)!

        let source = """
        (() => {
          const station = \(stationJSONString);
          const nativeStations = \(localStationsJSONString);
          const stationKey = 'subwave.stationOverride.v1';
          const customKey = 'subwave.customStations.v1';
          try {
            localStorage.setItem(customKey, JSON.stringify(nativeStations));
            localStorage.setItem(stationKey, station.slug);
          } catch (_) {}
          try {
            const originalFetch = window.fetch ? window.fetch.bind(window) : null;
            if (originalFetch && !window.__subwaveNativeFetchPatched) {
              window.__subwaveNativeFetchPatched = true;
              window.fetch = (input, init) => {
                try {
                  const raw = typeof input === 'string' ? input : input && input.url;
                  const url = new URL(raw || '', window.location.href);
                  if (url.pathname === '/stations.json') {
                    return Promise.resolve(new Response(JSON.stringify(nativeStations), {
                      status: 200,
                      headers: { 'Content-Type': 'application/json' }
                    }));
                  }
                } catch (_) {}
                return originalFetch(input, init);
              };
            }
          } catch (_) {}

          const handler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.subwaveNative;
          const streamLike = (value) => typeof value === 'string' && /\\/stream\\.(mp3|opus|flac|aac)(\\?|$)/.test(value);
          const isAudio = (el) => el && String(el.tagName).toUpperCase() === 'AUDIO';
          const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          const volumeDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
          const mutedDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
          const post = (payload) => {
            try {
              const h = handler();
              if (h) h.postMessage(payload);
            } catch (_) {}
          };
          const notifyPlaying = (el) => {
            setTimeout(() => {
              el.dispatchEvent(new Event('loadedmetadata'));
              el.dispatchEvent(new Event('canplay'));
              el.dispatchEvent(new Event('playing'));
            }, 0);
          };

          if (srcDescriptor) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
              configurable: true,
              enumerable: srcDescriptor.enumerable,
              get() {
                if (isAudio(this) && this.__subwaveNativeSrc) return this.__subwaveNativeSrc;
                return srcDescriptor.get.call(this);
              },
              set(value) {
                const next = String(value || '');
                if (isAudio(this) && streamLike(next)) {
                  this.__subwaveNativeSrc = next;
                  this.removeAttribute('src');
                  this.dispatchEvent(new Event('emptied'));
                  return;
                }
                this.__subwaveNativeSrc = '';
                srcDescriptor.set.call(this, value);
              }
            });
          }

          const originalPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function() {
            if (isAudio(this)) {
              const src = this.__subwaveNativeSrc || this.currentSrc || this.src;
              if (streamLike(src)) {
                post({ type: 'play', src, volume: this.volume, muted: this.muted });
                notifyPlaying(this);
                return Promise.resolve();
              }
            }
            return originalPlay.call(this);
          };

          const originalPause = HTMLMediaElement.prototype.pause;
          HTMLMediaElement.prototype.pause = function() {
            if (isAudio(this) && (this.__subwaveNativeSrc || streamLike(this.currentSrc || this.src))) {
              post({ type: 'pause' });
              this.dispatchEvent(new Event('pause'));
              return;
            }
            return originalPause.call(this);
          };

          if (volumeDescriptor) {
            Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
              configurable: true,
              enumerable: volumeDescriptor.enumerable,
              get() { return volumeDescriptor.get.call(this); },
              set(value) {
                volumeDescriptor.set.call(this, value);
                if (isAudio(this)) post({ type: 'volume', volume: this.volume, muted: this.muted });
              }
            });
          }

          if (mutedDescriptor) {
            Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
              configurable: true,
              enumerable: mutedDescriptor.enumerable,
              get() { return mutedDescriptor.get.call(this); },
              set(value) {
                mutedDescriptor.set.call(this, value);
                if (isAudio(this)) post({ type: 'volume', volume: this.volume, muted: this.muted });
              }
            });
          }
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
