import Foundation
import AirliftFFI

/// Drives the RPPairing host: requests Local Network, keeps the app alive while
/// the user approves the PIN in Settings, advertises the service over Bonjour,
/// and runs `al_pairing_run_host` off the main thread.
@MainActor
final class PairingController: ObservableObject {

    static let shared = PairingController()

    private let hostName = "CardArtWorkshop"
    private let hostModel = "Mac17,7"   // device sees a Mac-like pairing host
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    @Published private(set) var running = false
    @Published var pairingStatus: String = "idle"
    @Published var pairingPIN: String? = nil

    /// Path to the pairing file that was actively found or created.
    nonisolated(unsafe) static var customPairingFilePath: String? = nil

    /// Persisted altIRK keeps the host identity stable across pairings so a
    /// device that has already paired recognises this host.
    private static let altIRKKey = "aircardPairingHostAltIRK"
    nonisolated private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    // MARK: - Public API

    enum PairingError: LocalizedError {
        case busy
        case localNetworkDenied
        case zeroBytes
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Pairing is already in progress."
            case .localNetworkDenied: return "Local Network permission is off. Enable it in Settings › AirCard-iOS › Local Network."
            case .zeroBytes: return "Pairing produced an empty file. Approve the pairing request, then try again."
            case .timeout: return "配对超时，请确认已在设置中完成配对后重试。"
            case let .failed(msg): return msg
            }
        }
    }

    /// Ensures the given pairing file is mirrored to canonical aircard_pairing.plist and airlift_pairing.plist.
    @discardableResult
    nonisolated static func syncCanonicalPairingFile(from sourcePath: String) -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = dir.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = dir.appendingPathComponent("airlift_pairing.plist")

        if let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)), !data.isEmpty {
            if sourcePath != aircardURL.path {
                try? data.write(to: aircardURL, options: .atomic)
            }
            if sourcePath != airliftURL.path {
                try? data.write(to: airliftURL, options: .atomic)
            }
            customPairingFilePath = aircardURL.path
            return aircardURL.path
        }
        return sourcePath
    }

    /// Deletes every credential copy created or adopted by AirCard and clears the stored AltIRK.
    static func deleteStoredPairingCredentials() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = dir.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = dir.appendingPathComponent("airlift_pairing.plist")
        try? FileManager.default.removeItem(at: aircardURL)
        try? FileManager.default.removeItem(at: airliftURL)
        if let custom = customPairingFilePath {
            if custom != aircardURL.path && custom != airliftURL.path {
                try? FileManager.default.removeItem(atPath: custom)
            }
            customPairingFilePath = nil
        }
        storedAltIRK = ""
    }

    /// Path where the pairing file is written or read from.
    /// Checks for canonical aircard_pairing.plist, airlift_pairing.plist, or custom path.
    nonisolated static func pairingFilePath() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardPath = dir.appendingPathComponent("aircard_pairing.plist").path
        if FileManager.default.fileExists(atPath: aircardPath) {
            let size = (try? FileManager.default.attributesOfItem(atPath: aircardPath)[.size] as? Int) ?? 0
            if size > 0 { return aircardPath }
        }

        let airliftPath = dir.appendingPathComponent("airlift_pairing.plist").path
        if FileManager.default.fileExists(atPath: airliftPath) {
            let size = (try? FileManager.default.attributesOfItem(atPath: airliftPath)[.size] as? Int) ?? 0
            if size > 0 {
                _ = syncCanonicalPairingFile(from: airliftPath)
                return aircardPath
            }
        }

        if let custom = customPairingFilePath, FileManager.default.fileExists(atPath: custom) {
            let size = (try? FileManager.default.attributesOfItem(atPath: custom)[.size] as? Int) ?? 0
            if size > 0 {
                _ = syncCanonicalPairingFile(from: custom)
                return aircardPath
            }
        }

        return aircardPath
    }

    /// Start the host and resolve with the pairing-file path, or throw.
    func startAndWait() async throws -> String {
        // If already running, cancel previous to allow clean restart
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in
                    self.pairContinuation = cont
                    self.start()
                }
            }
            // 超时保护：120s 未完成则放弃，避免卡死
            group.addTask {
                try await Task.sleep(nanoseconds: 120_000_000_000)
                throw PairingError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func softCancel() {
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        pairingPIN = nil
        pairingStatus = "Cancelled"
        PINNotifier.withdrawPIN()
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "Starting local host…"

        // 用户马上会切到「设置」输码，提前请求通知授权
        PINNotifier.requestAuthorization()

        Task {
            _ = await localNetwork.request()
            guard running else { return }

            keepAlive.startAudio()
            pairingStatus = "Broadcasting… open Settings to pair"
            runHost()
        }
    }

    // MARK: - Private

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        let altIRK = Self.storedAltIRK
        nonisolated(unsafe) let ctx = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairReadyCallback, pairPinCallback, ctx, &result)
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                let devName = cStr(result.device_name)
                let filePath = cStr(result.pairing_file_path)
                outcome = .success(
                    name: devName.isEmpty ? "iPhone" : devName,
                    path: filePath.isEmpty ? outPath : filePath
                )
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }
            al_pairing_result_free(&result)

            DispatchQueue.main.async {
                Unmanaged<PairingController>.fromOpaque(ctx).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        stopAdvertising()
        // 配对后保持音频保活更久，给用户从设置返回留足时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            self?.keepAlive.stopAll()
        }
        running = false
        pairingPIN = nil

        switch outcome {
        case let .success(name, path):
            let canonical = Self.syncCanonicalPairingFile(from: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0
            if size == 0 {
                PINNotifier.withdrawPIN()
                pairingStatus = "Failed: empty pairing file"
                resolve(.failure(PairingError.zeroBytes))
            } else {
                PINNotifier.postPaired(deviceName: name)
                pairingStatus = "Paired: \(name) (\(size)B)"
                resolve(.success(canonical))
            }
        case let .failure(message):
            pairingStatus = "Failed: \(message)"
            resolve(.failure(PairingError.failed(message)))
        }
    }


    // MARK: Bonjour advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "Advertising — open Settings › Privacy & Security › Developer Mode"
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "Enter PIN \(pin) in Settings › Privacy & Security › Developer Mode › Pair with AirCard-iOS"
        // 用户已在设置页时 App 退到后台，PIN 靠系统通知传达
        PINNotifier.postPIN(pin)
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

private let pairReadyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: ALPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}

