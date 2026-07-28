import Cocoa
import AVFoundation
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let startURL = URL(string: "https://player.kjho.me/?skin=prism")!
    private let appUserAgentToken = "SubwavePrism/1.0"
    private let stationDefaultsKey = "stationURL"
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
        alert.messageText = "Station URL"
        alert.informativeText = "Enter the base URL for a SUB/WAVE station."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = stationURL().absoluteString
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            guard let normalized = normalizeStationURL(field.stringValue) else {
                showStationURLError()
                return
            }
            UserDefaults.standard.set(normalized.absoluteString, forKey: stationDefaultsKey)
            stopNativePlayback()
            loadStartURL()
        }
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

        let source = """
        (() => {
          const station = \(stationJSONString);
          const stationKey = 'subwave.stationOverride.v1';
          const customKey = 'subwave.customStations.v1';
          try {
            const existing = JSON.parse(localStorage.getItem(customKey) || '[]')
              .filter((item) => item && item.url !== station.url && item.slug !== station.slug);
            localStorage.setItem(customKey, JSON.stringify([station, ...existing]));
            localStorage.setItem(stationKey, station.slug);
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
