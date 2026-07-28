import Cocoa
import AVFoundation
import MediaToolbox
import WebKit

private struct NativeStation: Codable {
    let slug: String
    let name: String
    let url: String
    let location: String?
    let genre: String?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private let startURL = URL(string: "https://player.kjho.me/?skin=prism")!
    private let stationDirectoryURL = URL(string: "https://player.kjho.me/stations.json")!
    private let appUserAgentToken = "SubwavePrism/1.0"
    private let stationDefaultsKey = "stationURL"
    private let stationSlugDefaultsKey = "stationSlug"
    private let stationNameDefaultsKey = "stationName"
    private let stationLocationDefaultsKey = "stationLocation"
    private let defaultStationURL = "https://radio.gurthyy.xyz"
    private let nativeSpectrumBands = 64
    private var window: NSWindow!
    private var webView: WKWebView!
    private var player: AVPlayer?
    private var playerAsset: AVURLAsset?
    private var currentNativeStreamURL: URL?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var lastSpectrumPush = Date.distantPast

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
        fetchStationDirectory { [weak self] stations in
            self?.presentStationSettings(stations: stations)
        }
    }

    private func presentStationSettings(stations: [NativeStation]) {
        let alert = NSAlert()
        alert.messageText = "Station"
        alert.informativeText = "Choose a SUB/WAVE station or enter a custom base URL."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        let saved = stationMetadata()
        let allStations = stationOptions(directory: stations)
        var selectedIndex = 0
        for (index, station) in allStations.enumerated() {
            popup.addItem(withTitle: station.location.map { "\(station.name) - \($0)" } ?? station.name)
            popup.item(at: index)?.representedObject = station.url
            if normalizeStationURL(station.url)?.absoluteString == normalizeStationURL(saved.url)?.absoluteString {
                selectedIndex = index
            }
        }
        popup.addItem(withTitle: "Custom URL...")
        popup.selectItem(at: selectedIndex)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = saved.url

        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 58)
        alert.accessoryView = stack

        if alert.runModal() == .alertFirstButtonReturn {
            let selectedURL = popup.selectedItem?.representedObject as? String
            let rawURL = selectedURL ?? field.stringValue
            guard let normalized = normalizeStationURL(rawURL) else {
                showStationURLError()
                return
            }
            let selectedStation = allStations.first { normalizeStationURL($0.url)?.absoluteString == normalized.absoluteString }
            saveStation(url: normalized, station: selectedStation)
            stopNativePlayback()
            loadStartURL()
        }
    }

    private func fetchStationDirectory(completion: @escaping ([NativeStation]) -> Void) {
        let task = URLSession.shared.dataTask(with: stationDirectoryURL) { data, _, _ in
            let stations: [NativeStation]
            if let data,
               let decoded = try? JSONDecoder().decode([NativeStation].self, from: data) {
                stations = decoded
            } else {
                stations = []
            }
            DispatchQueue.main.async {
                completion(stations)
            }
        }
        task.resume()
    }

    private func stationOptions(directory: [NativeStation]) -> [NativeStation] {
        var seen = Set<String>()
        let saved = stationMetadata()
        let savedStation = NativeStation(
            slug: saved.slug,
            name: saved.name,
            url: saved.url,
            location: saved.location,
            genre: nil
        )
        return ([savedStation] + directory).filter { station in
            guard let normalized = normalizeStationURL(station.url)?.absoluteString else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private func saveStation(url: URL, station: NativeStation?) {
        let defaults = UserDefaults.standard
        defaults.set(url.absoluteString, forKey: stationDefaultsKey)
        defaults.set(station?.slug ?? stationSlug(for: url), forKey: stationSlugDefaultsKey)
        defaults.set(station?.name ?? url.host ?? "Saved station", forKey: stationNameDefaultsKey)
        if let location = station?.location {
            defaults.set(location, forKey: stationLocationDefaultsKey)
        } else {
            defaults.removeObject(forKey: stationLocationDefaultsKey)
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
        return normalizeStationURL(stationMetadata().url) ?? URL(string: defaultStationURL)!
    }

    private func stationMetadata() -> NativeStation {
        let defaults = UserDefaults.standard
        let url: URL
        if let stored = defaults.string(forKey: stationDefaultsKey),
           let url = normalizeStationURL(stored) {
            return NativeStation(
                slug: defaults.string(forKey: stationSlugDefaultsKey) ?? stationSlug(for: url),
                name: defaults.string(forKey: stationNameDefaultsKey) ?? url.host ?? "Saved station",
                url: url.absoluteString,
                location: defaults.string(forKey: stationLocationDefaultsKey),
                genre: nil
            )
        }
        url = URL(string: defaultStationURL)!
        return NativeStation(
            slug: stationSlug(for: url),
            name: url.host ?? "Saved station",
            url: url.absoluteString,
            location: "Native app",
            genre: nil
        )
    }

    private func stationSlug(for url: URL) -> String {
        let host = url.host ?? "station"
        return "native-\(host.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression))"
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
            let item = AVPlayerItem(asset: asset)
            installAudioTap(on: item)
            player = AVPlayer(playerItem: item)
        }
        player?.volume = muted ? 0 : Float(max(0, min(1, volume)))
        player?.play()
    }

    private func installAudioTap(on item: AVPlayerItem) {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: nativeAudioTapInit,
            finalize: nativeAudioTapFinalize,
            prepare: nativeAudioTapPrepare,
            unprepare: nativeAudioTapUnprepare,
            process: nativeAudioTapProcess
        )
        var tapRef: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tapRef
        )
        guard status == noErr, let tap = tapRef?.takeRetainedValue() else { return }

        let parameters = AVMutableAudioMixInputParameters()
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
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
        publishNativeSpectrum(Array(repeating: 0, count: nativeSpectrumBands))
    }

    fileprivate func handleNativeAudio(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
        let frames = max(1, Int(frameCount))
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var bands = Array(repeating: Float(0), count: nativeSpectrumBands)
        var counts = Array(repeating: 0, count: nativeSpectrumBands)

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let channelFrames = min(frames, sampleCount)
            let stride = max(1, channelFrames / 512)
            var index = 0
            while index < channelFrames {
                let band = min(nativeSpectrumBands - 1, index * nativeSpectrumBands / channelFrames)
                bands[band] += abs(samples[index])
                counts[band] += 1
                index += stride
            }
        }

        let levels = bands.enumerated().map { index, sum -> Int in
            guard counts[index] > 0 else { return 0 }
            let avg = sum / Float(counts[index])
            return min(255, max(0, Int(pow(avg, 0.55) * 280)))
        }
        publishNativeSpectrum(levels)
    }

    private func publishNativeSpectrum(_ levels: [Int]) {
        let now = Date()
        guard now.timeIntervalSince(lastSpectrumPush) >= 1.0 / 30.0 || levels.allSatisfy({ $0 == 0 }) else { return }
        lastSpectrumPush = now
        guard let data = try? JSONSerialization.data(withJSONObject: levels),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__subwaveNativeAudioFrame && window.__subwaveNativeAudioFrame(\(json));", completionHandler: nil)
        }
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
          const NativeAudioContext = window.AudioContext || window.webkitAudioContext;
          const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
          const volumeDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
          const mutedDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
          window.__subwaveNativeSpectrum = [];
          window.__subwaveNativeSpectrumActive = false;
          window.__subwaveNativeAudioFrame = (levels) => {
            if (!Array.isArray(levels)) return;
            window.__subwaveNativeSpectrum = levels.map((value) => Math.max(0, Math.min(255, Number(value) || 0)));
            window.__subwaveNativeSpectrumActive = window.__subwaveNativeSpectrum.some((value) => value > 0);
          };
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

          if (NativeAudioContext && NativeAudioContext.prototype && !NativeAudioContext.prototype.__subwaveNativeAnalyserPatched) {
            const originalCreateAnalyser = NativeAudioContext.prototype.createAnalyser;
            Object.defineProperty(NativeAudioContext.prototype, '__subwaveNativeAnalyserPatched', { value: true });
            NativeAudioContext.prototype.createAnalyser = function() {
              const analyser = originalCreateAnalyser.call(this);
              const originalGetByteFrequencyData = analyser.getByteFrequencyData.bind(analyser);
              analyser.getByteFrequencyData = (target) => {
                const source = window.__subwaveNativeSpectrum || [];
                if (!window.__subwaveNativeSpectrumActive || source.length === 0) {
                  originalGetByteFrequencyData(target);
                  return;
                }
                for (let i = 0; i < target.length; i += 1) {
                  const position = target.length <= 1 ? 0 : (i / (target.length - 1)) * (source.length - 1);
                  const left = Math.floor(position);
                  const right = Math.min(source.length - 1, left + 1);
                  const mix = position - left;
                  target[i] = Math.round((source[left] || 0) * (1 - mix) + (source[right] || 0) * mix);
                }
              };
              return analyser;
            };
          }
        })();
        """

        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}

private func nativeAudioTapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func nativeAudioTapFinalize(tap: MTAudioProcessingTap) {}

private func nativeAudioTapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {}

private func nativeAudioTapUnprepare(tap: MTAudioProcessingTap) {}

private func nativeAudioTapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        numberFramesOut
    )
    let storage = MTAudioProcessingTapGetStorage(tap)
    let app = Unmanaged<AppDelegate>.fromOpaque(storage).takeUnretainedValue()
    app.handleNativeAudio(bufferList: bufferListInOut, frameCount: numberFramesOut.pointee)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
