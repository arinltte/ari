//
//  MLXClient.swift
//  Ari
//
//  Created by Chen Jin Shen on 21/05/2026.
//

import Foundation
import Combine
import AppKit

extension Notification.Name {
    static let windowMovableChanged = Notification.Name("windowMovableChanged")
    static let menuBarIconChanged = Notification.Name("menuBarIconChanged")
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

struct MLXRequest: Codable {
    let model: String
    let messages: [MLXMessage]
    let stream: Bool
    let max_tokens: Int
}

struct MLXMessage: Codable {
    let role: String
    let content: MLXContent
}

enum MLXContent: Codable {
    case text(String)
    case multimodal([MLXContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let str): try container.encode(str)
        case .multimodal(let blocks): try container.encode(blocks)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { self = .text(str) }
        else if let blocks = try? container.decode([MLXContentBlock].self) { self = .multimodal(blocks) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid content type") }
    }
}

struct MLXContentBlock: Codable {
    let type: String
    let text: String?
    let image_url: MLXImageUrl?
}

struct MLXImageUrl: Codable {
    let url: String
}

struct MLXChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

enum SetupState: Equatable {
    case checking
    case installing
    case pythonTooOld(String)
    case error
    case ready
}

actor DownloadErrorTracker {
    var lastErrorLine: String = "Unknown error occurred"
    func update(_ line: String) { self.lastErrorLine = line }
}

class MLXClient: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var currentStreamingResponse: String = ""
    @Published var isGenerating: Bool = false
    @Published var errorMessage: String? = nil
    @Published var availableModels: [String] = []

    @Published var setupState: SetupState = .checking
    @Published var setupProgressText: String = "Checking environment..."
    @Published var showSettingsTrigger: Bool = false

    @Published var hfRepoId: String = ""
    @Published var hfRepoValid: Bool? = nil
    @Published var isDownloadingModel: Bool = false
    @Published var downloadProgressText: String = ""
    @Published var downloadError: String? = nil

    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    
    @Published var idleTimeoutSeconds: Int = UserDefaults.standard.object(forKey: "idleTimeoutSeconds") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(idleTimeoutSeconds, forKey: "idleTimeoutSeconds"); resetIdleTimer() }
    }
    
    @Published var isWindowMovable: Bool = UserDefaults.standard.bool(forKey: "isWindowMovable") {
        didSet {
            UserDefaults.standard.set(isWindowMovable, forKey: "isWindowMovable")
            NotificationCenter.default.post(name: .windowMovableChanged, object: nil, userInfo: ["value": isWindowMovable])
        }
    }
    
    @Published var menuBarIcon: String = UserDefaults.standard.string(forKey: "menuBarIcon") ?? "bolt.fill" {
        didSet {
            UserDefaults.standard.set(menuBarIcon, forKey: "menuBarIcon")
            NotificationCenter.default.post(name: .menuBarIconChanged, object: nil, userInfo: ["icon": menuBarIcon])
        }
    }

    var modelLoaded = false
    @Published var isStartingServer = false

    private let baseUrl = URL(string: "http://127.0.0.1:8080/v1/chat/completions")!
    private let serverPort = 8080
    private let serverModelName = "default_model"
    private var activeTask: Task<Void, Never>?
    private var serverProcess: Process?
    private var pendingPrompt: String? = nil
    private var idleTimer: Timer?
    private var serverGeneration: Int = 0
    private var currentGenerationID: UUID?

    let ariDirectory: URL
    let modelsDirectory: URL
    let pythonDirectory: URL
    let cacheDirectory: URL

    private var currentModelPath: String {
        return modelsDirectory.appendingPathComponent(selectedModel).path
    }

    init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        ariDirectory = homeDirectory.appendingPathComponent(".ari")
        modelsDirectory = ariDirectory.appendingPathComponent("Models")
        pythonDirectory = ariDirectory.appendingPathComponent("Python")
        cacheDirectory = ariDirectory.appendingPathComponent("Cache")

        createDirectoryIfNeeded()
        discoverModelFolders()
        NotificationCenter.default.post(name: .windowMovableChanged, object: nil, userInfo: ["value": isWindowMovable])
        checkAndSetupEnvironment()
    }

    func createDirectoryIfNeeded() {
        let fm = FileManager.default
        for folder in ["Models", "Python", "Cache", "Logs", "Config"] {
            let url = ariDirectory.appendingPathComponent(folder)
            if !fm.fileExists(atPath: url.path) { try? fm.createDirectory(at: url, withIntermediateDirectories: true) }
        }
    }

    private func discoverModelFolders() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            self.availableModels = contents.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }.map { $0.lastPathComponent }
            
            if selectedModel.isEmpty, let first = availableModels.first { self.selectedModel = first }
            else if !selectedModel.isEmpty && !availableModels.contains(selectedModel), let first = availableModels.first { self.selectedModel = first }
            
            if availableModels.isEmpty { DispatchQueue.main.async { self.showSettingsTrigger = true } }
        } catch { print("[MLXClient] Could not read models directory: \(error)") }
    }

    func fetchAvailableModels() { discoverModelFolders() }
    
    func deleteModel(_ name: String) {
        guard !name.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: modelsDirectory.appendingPathComponent(name).path)
        if selectedModel == name { selectedModel = "" }
        fetchAvailableModels()
    }

    private func checkAndSetupEnvironment() {
        Task.detached {
            print("[Ari Setup] Checking Python version...")

            // Find whatever python3 the system provides
            let checkTask = Process()
            checkTask.executableURL = URL(fileURLWithPath: "/bin/bash")
            checkTask.arguments = ["-c", """
                export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
                for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
                    full_path=$(command -v "$candidate" 2>/dev/null || true)
                    if [ -n "$full_path" ]; then
                        version=$("$full_path" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" 2>/dev/null || true)
                        if [ -n "$version" ]; then
                            echo "$full_path|$version"
                            break
                        fi
                    fi
                done
            """]
            let pipe = Pipe()
            checkTask.standardOutput = pipe
            checkTask.standardError = FileHandle.nullDevice
            try? checkTask.run()
            checkTask.waitUntilExit()

            let output = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            print("[Ari Setup] Python probe output: '\(output)'")

            // Parse "path|major.minor.micro"
            let parts = output.components(separatedBy: "|")
            if parts.count == 2 {
                let versionString = parts[1]
                let components = versionString.components(separatedBy: ".").compactMap { Int($0) }
                let major = components.count > 0 ? components[0] : 0
                let minor = components.count > 1 ? components[1] : 0

                if major < 3 || (major == 3 && minor < 10) {
                    print("[Ari Setup] Python \(versionString) is too old (need 3.10+). Blocking setup.")
                    Task { @MainActor in
                        self.setupState = .pythonTooOld(versionString)
                    }
                    return
                }
                print("[Ari Setup] Python \(versionString) OK. Proceeding with setup.")
            } else {
                // No python found at all — also block
                print("[Ari Setup] No Python found. Blocking setup.")
                Task { @MainActor in
                    self.setupState = .pythonTooOld("not found")
                }
                return
            }

            Task { @MainActor in self.runSetupScript() }
        }
    }

    private func runSetupScript() {
        self.setupState = .installing
        self.setupProgressText = "Initializing Python Environment in ~/.ari/Python..."

        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")

            let script = """
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            if ! command -v python3 &> /dev/null; then echo "ERROR: python3 not found."; exit 1; fi
            python3 -m venv "\(self.pythonDirectory.path)"
            source "\(self.pythonDirectory.path)/bin/activate"
            pip install -U pip
            WHEELS_DIR="$(dirname "$(dirname "$(which python3)")")/../../Resources/ari_wheels"
            if [ -d "$WHEELS_DIR" ]; then
                echo "Using bundled wheels..."
                pip install --find-links "$WHEELS_DIR" --prefer-binary \
                    mlx-lm mlx-vlm "huggingface_hub[cli]" hf_transfer torch torchvision
            else
                pip install -U mlx-lm mlx-vlm "huggingface_hub[cli]" hf_transfer torch torchvision
            fi
            if command -v brew &>/dev/null; then brew install huggingface-cli 2>/dev/null || true; fi
            """
            task.arguments = ["-c", script]

            let pipe = Pipe()
            task.standardOutput = pipe; task.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.count > 0, let str = String(data: data, encoding: .utf8) {
                    for line in str.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        print("[Ari Setup] \(trimmed)")
                        Task { @MainActor in self.setupProgressText = trimmed }
                    }
                }
            }

            do {
                try task.run()
                task.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    if task.terminationStatus == 0 { self.setupState = .ready; self.fetchAvailableModels() }
                    else { self.setupState = .error; self.setupProgressText = "Installation failed (Code \(task.terminationStatus))." }
                }
            } catch {
                Task { @MainActor in self.setupState = .error; self.setupProgressText = error.localizedDescription }
            }
        }
    }

    @MainActor
    func validateRepo(id: String) async {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { hfRepoValid = nil; return }
        guard let url = URL(string: "https://huggingface.co/api/models/\(cleanId)") else { hfRepoValid = false; return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let (_, response) = try? await URLSession.shared.data(for: req), let http = response as? HTTPURLResponse, http.statusCode == 200 { hfRepoValid = true } else { hfRepoValid = false }
    }
    
    private func directorySize(url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []  // no .skipsHiddenFiles — counts .incomplete partial files
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    func downloadHuggingFaceModel(id: String) {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return }
        let folderName = cleanId.components(separatedBy: "/").last ?? "Downloaded_Model"
        let destURL = modelsDirectory.appendingPathComponent(folderName)

        Task { @MainActor in
            self.downloadError = nil
            self.isDownloadingModel = true
            self.downloadProgressText = "Fetching repo info…"

            // 1. Get actual total byte size from HF API
            var totalBytes: Int64 = 0
            if let apiURL = URL(string: "https://huggingface.co/api/models/\(cleanId)?blobs=true"),
               let (data, _) = try? await URLSession.shared.data(from: apiURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let siblings = json["siblings"] as? [[String: Any]] {
                for sib in siblings {
                    // JSONSerialization returns Int, not Int64 — must cast via Int first
                    if let lfs = sib["lfs"] as? [String: Any] {
                        if let size = lfs["size"] as? Int { totalBytes += Int64(size) }
                        else if let size = lfs["size"] as? Double { totalBytes += Int64(size) }
                    } else {
                        if let size = sib["size"] as? Int { totalBytes += Int64(size) }
                        else if let size = sib["size"] as? Double { totalBytes += Int64(size) }
                    }
                }
            }

            self.downloadProgressText = "Starting download for \(folderName)…"

            let capturedTotal = totalBytes
            let capturedDest = destURL
            let capturedName = folderName

            // 2. Poll directory size every second for real percentage
            let pollingTask = Task { @MainActor in
                guard capturedTotal > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    var current = self.directorySize(url: capturedDest)
                    let parts = cleanId.components(separatedBy: "/")
                    if parts.count == 2 {
                        let hfCache = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".cache/huggingface/hub/models--\(parts[0])--\(parts[1])")
                        current = max(current, self.directorySize(url: hfCache))
                    }
                    let pct = min(Int(Double(current) / Double(capturedTotal) * 100), 99)
                    self.downloadProgressText = "Downloading \(capturedName)… \(pct)%"
                }
            }

            // 3. Run download process
            Task.detached {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                let script = """
                export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
                source "\(self.pythonDirectory.path)/bin/activate" 2>/dev/null
                if command -v hf &> /dev/null; then CMD="hf"; elif command -v huggingface-cli &> /dev/null; then CMD="huggingface-cli"; else exit 1; fi
                $CMD download "\(cleanId)" --local-dir "\(capturedDest.path)"
                """
                task.arguments = ["-c", script]

                let pipe = Pipe()
                task.standardOutput = pipe; task.standardError = pipe
                let errorTracker = DownloadErrorTracker()

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.count > 0, let str = String(data: data, encoding: .utf8) {
                        for line in str.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { Task { await errorTracker.update(trimmed) } }
                        }
                    }
                }

                do {
                    try task.run()
                    task.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let finalStatus = task.terminationStatus
                    let finalErrorLine = await errorTracker.lastErrorLine
                    pollingTask.cancel()
                    Task { @MainActor in
                        self.isDownloadingModel = false
                        if finalStatus == 0 {
                            self.downloadProgressText = "Download complete!"
                            self.hfRepoId = ""; self.hfRepoValid = nil
                            self.fetchAvailableModels()
                            if self.availableModels.contains(capturedName) { self.selectedModel = capturedName }
                        } else {
                            self.downloadError = "Download failed: \(finalErrorLine)"
                        }
                    }
                } catch {
                    pollingTask.cancel()
                    Task { @MainActor in self.isDownloadingModel = false; self.downloadError = "Failed to spawn task." }
                }
            }
        }
    }

    private func detectVisionModel(at path: String) -> Bool {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: url.appendingPathComponent("preprocessor_config.json").path) { return true }
        if fm.fileExists(atPath: url.appendingPathComponent("processor_config.json").path) { return true }
        
        let configPath = url.appendingPathComponent("config.json").path
        guard let data = fm.contents(atPath: configPath), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        
        if let modelType = config["model_type"] as? String {
            let vlmTypes: Set<String> = ["gemma4_vlm", "llava", "phi3_v", "fuyu", "pixtral", "idefics", "qwen2_vl", "qwen2_5_vl", "mllama", "internvl", "deepseek_vl", "cogvlm", "cogagent", "paddleocr_vl", "vlm", "smollm_vlm", "molmo", "aya_vision", "gemma3", "gemma4", "paligemma"]
            if vlmTypes.contains(modelType.lowercased()) { return true }
        }
        return false
    }

    private func cleanModelCache() {
        let localCache = URL(fileURLWithPath: currentModelPath).appendingPathComponent(".cache").path
        if FileManager.default.fileExists(atPath: localCache) { try? FileManager.default.removeItem(atPath: localCache) }
    }

    func suspendIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func resetIdleTimer() {
        idleTimer?.invalidate(); idleTimer = nil
        guard idleTimeoutSeconds > 0, modelLoaded else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(idleTimeoutSeconds), repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.shutdownServer() }
        }
    }

    private func shutdownServer() {
        killProcessOnPort(); modelLoaded = false
        if errorMessage == nil || !(errorMessage?.hasPrefix("❌") ?? false) { errorMessage = "Server went idle. It will wake up automatically when you type." }
        print("[MLXClient] Server shutdown due to idle.")
    }

    private func killProcessOnPort() {
        serverProcess?.terminationHandler = nil; serverProcess?.terminate(); serverProcess = nil
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); lsof.arguments = ["-ti", ":\(serverPort)", "-sTCP:LISTEN"]
        let pipe = Pipe(); lsof.standardOutput = pipe; lsof.standardError = FileHandle.nullDevice; lsof.standardInput = FileHandle.nullDevice
        do {
            try lsof.run(); lsof.waitUntilExit()
            if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                for pidStr in output.components(separatedBy: .newlines) where Int(pidStr.trimmingCharacters(in: .whitespaces)) != nil {
                    let kill = Process(); kill.executableURL = URL(fileURLWithPath: "/bin/kill"); kill.arguments = ["-9", pidStr.trimmingCharacters(in: .whitespaces)]; try? kill.run(); kill.waitUntilExit()
                }
            }
        } catch { }
    }

    func startServer(for modelName: String) {
        guard !modelName.isEmpty, !isStartingServer else { return }
        suspendIdleTimer(); serverGeneration += 1
        let currentGen = serverGeneration
        isStartingServer = true; modelLoaded = false
        killProcessOnPort()

        let modelPath = currentModelPath
        let isVLM = detectVisionModel(at: modelPath)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.serverGeneration == currentGen else { return }
            self.cleanModelCache()
            self.errorMessage = "Loading \(modelName) into memory…"
            print("[MLXClient] Starting Server. isVLM: \(isVLM)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            
            let script = """
            export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
            source "\(self.pythonDirectory.path)/bin/activate"
            if [ "\(isVLM)" == "true" ]; then
                exec python3 -m mlx_vlm.server --model "\(modelPath)" --host 127.0.0.1 --port \(self.serverPort)
            else
                exec python3 -m mlx_lm server --model "\(modelPath)" --prompt-cache-size 0 --host 127.0.0.1 --port \(self.serverPort)
            fi
            """
            process.arguments = ["-c", script]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(self.pythonDirectory.path)/bin:" + (env["PATH"] ?? "")
            env["VIRTUAL_ENV"] = self.pythonDirectory.path
            env["PYTHONUNBUFFERED"] = "1"
            env["HF_HUB_OFFLINE"] = "1"
            env["HF_HOME"] = self.cacheDirectory.path
            env["HF_HUB_CACHE"] = self.cacheDirectory.path
            
            // FIX: Disables Xcode Metal API Validation which crashes MLX on M4 Macs!
            env["MTL_DEBUG_LAYER"] = "0"
            env["MTL_SHADER_VALIDATION"] = "0"
            env["MTL_CAPTURE_ENABLED"] = "0"
            
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if let string = String(data: handle.availableData, encoding: .utf8), !string.isEmpty {
                    print("[SERVER LOG] \(string.trimmingCharacters(in: .newlines))")
                }
            }

            process.terminationHandler = { [weak self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    print("[MLXClient] Server process terminated with status \(proc.terminationStatus)")
                    guard let self = self, self.serverGeneration == currentGen, self.isStartingServer else { return }
                    if proc.terminationStatus != 0 {
                        self.errorMessage = "❌ Server crashed (Code \(proc.terminationStatus)). Check logcat."
                    }
                    self.isStartingServer = false
                }
            }

            do {
                try process.run()
                self.serverProcess = process
                self.pollAndWarmUp(gen: currentGen, modelPath: modelPath)
            }
            catch {
                self.errorMessage = "❌ Cannot launch server script."
                self.isStartingServer = false
            }
        }
    }

    private func pollAndWarmUp(gen: Int, modelPath: String) {
        Task { @MainActor in
            var attempt = 0
            self.errorMessage = "Warming up model weights…"
            
            while attempt < 360 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self.serverGeneration == gen, self.isStartingServer else { return }
                
                var request = URLRequest(url: self.baseUrl)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 3
                
                let body = MLXRequest(model: modelPath, messages: [MLXMessage(role: "user", content: .text("Hi"))], stream: false, max_tokens: 1)
                request.httpBody = try? JSONEncoder().encode(body)
                
                do {
                    let (_, resp) = try await URLSession.shared.data(for: request)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 400 {
                        print("[MLXClient] Warm-up successful. Server is listening.")
                        self.modelLoaded = true
                        self.isStartingServer = false
                        self.errorMessage = nil
                        self.resetIdleTimer()
                        if let pending = self.pendingPrompt { self.pendingPrompt = nil; self.generate(prompt: pending) }
                        return
                    }
                } catch {
                    // Connection refused, wait and loop again
                }
                attempt += 1
            }
            self.errorMessage = "⏱ Server start timed out."
            self.isStartingServer = false
            print("[MLXClient] Server poll timed out after 180s.")
        }
    }

    // MARK: - Generation (Rethought)

    @MainActor
    func generate(prompt: String) {
        if !modelLoaded && !isStartingServer { pendingPrompt = prompt; startServer(for: selectedModel); return }
        else if isStartingServer { pendingPrompt = prompt; return }

        suspendIdleTimer()
        activeTask?.cancel()

        messages.append(ChatMessage(isUser: true, text: prompt))

        let generationID = UUID()
        currentGenerationID = generationID

        isGenerating = true
        errorMessage = nil
        currentStreamingResponse = ""
        print("[MLXClient] Starting generation [\(generationID)]...")

        activeTask = Task { [weak self] in
            guard let self = self else { return }

            // Single atomic commit when this generation finishes — no matter how it ends.
            defer {
                Task { @MainActor in
                    guard self.currentGenerationID == generationID else {
                        print("[MLXClient] Generation \(generationID) defer skipped (superseded).")
                        return
                    }
                    if !self.currentStreamingResponse.isEmpty {
                        self.messages.append(ChatMessage(isUser: false, text: self.currentStreamingResponse))
                        self.currentStreamingResponse = ""
                    }
                    self.isGenerating = false
                    self.resetIdleTimer()
                }
            }

            let mlxMessages = self.messages.filter { !$0.text.isEmpty }.map {
                MLXMessage(role: $0.isUser ? "user" : "assistant", content: .text($0.text))
            }
            var success = false

            for modelName in [self.currentModelPath] {
                var request = URLRequest(url: self.baseUrl)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 120
                request.httpBody = try? JSONEncoder().encode(
                    MLXRequest(model: modelName, messages: mlxMessages, stream: true, max_tokens: 4096)
                )

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 200 {
                            await self.processStream(bytes: bytes, generationID: generationID)
                            success = true
                            break
                        } else {
                            await MainActor.run {
                                guard self.currentGenerationID == generationID else { return }
                                self.errorMessage = "❌ Server rejected request (Code \(http.statusCode))."
                            }
                            print("[MLXClient] HTTP Error \(http.statusCode)")
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self.currentGenerationID == generationID else { return }
                        self.errorMessage = "❌ Network error: \(error.localizedDescription)"
                    }
                    print("[MLXClient] Generation Request Error: \(error)")
                }
            }

            if !success {
                await MainActor.run {
                    guard self.currentGenerationID == generationID else { return }
                    if self.errorMessage == nil {
                        self.errorMessage = "❌ Failed to generate response."
                    }
                }
            }
        }
    }

    /// Reads the SSE stream off-main-actor, batches UI updates, and respects generation identity.
    private func processStream(bytes: URLSession.AsyncBytes, generationID: UUID) async {
        var buffer = ""
        var lastFlush = Date()

        do {
            for try await line in bytes.lines {
                guard !Task.isCancelled else { break }

                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                guard cleanLine.hasPrefix("data: ") else { continue }

                let jsonString = String(cleanLine.dropFirst(6))
                if jsonString == "[DONE]" { break }

                guard
                    let data = jsonString.data(using: .utf8),
                    let chunk = try? JSONDecoder().decode(MLXChunk.self, from: data),
                    let text = chunk.choices.first?.delta.content
                else { continue }

                buffer += text
                //print("[RAW STREAM] \(text)", terminator: "")

                // Batch flush every ~30 ms to avoid hammering MainActor / SwiftUI.
                if Date().timeIntervalSince(lastFlush) > 0.03 {
                    let batch = buffer
                    buffer = ""
                    await MainActor.run {
                        guard self.currentGenerationID == generationID else { return }
                        self.currentStreamingResponse += batch
                    }
                    lastFlush = Date()
                }
            }
        } catch {
            // Expected on cancellation or connection drop.
            print("[MLXClient] Stream error (benign if cancelled): \(error)")
        }

        // Flush any remaining buffered text.
        if !buffer.isEmpty {
            await MainActor.run {
                guard self.currentGenerationID == generationID else { return }
                self.currentStreamingResponse += buffer
            }
        }
    }

    func stopGeneration() {
        activeTask?.cancel()
        // The Task's defer handles cleanup. We do NOT touch isGenerating here
        // so that a superseded generation doesn't clobber a new one.
    }

    func clearHistory() {
        activeTask?.cancel()
        messages.removeAll()
        currentStreamingResponse = ""
        errorMessage = nil
        isGenerating = false
        currentGenerationID = nil
    }
    
    func regenerateLast() {
        guard !isGenerating else { return }
        guard let lastUserMsg = messages.last(where: { $0.isUser }) else { return }
        let prompt = lastUserMsg.text
        // Strip trailing assistant message(s)
        while let last = messages.last, !last.isUser { messages.removeLast() }
        // Strip the last user message — generate() will re-append it
        if messages.last?.isUser == true { messages.removeLast() }
        generate(prompt: prompt)
    }

    func restartServer() {
        isStartingServer = false
        pendingPrompt = nil
        startServer(for: selectedModel)
    }
}
