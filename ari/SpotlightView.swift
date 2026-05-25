//
//  SpotlightView.swift
//  Ari
//
//  Created by Chen Jin Shen on 21/05/2026.
//

import SwiftUI

struct SpotlightView: View {
    @StateObject var client = MLXClient()
    var onClose: () -> Void

    @State private var prompt: String = ""
    @FocusState private var isInputFieldFocused: Bool
    
    @State private var showSettings: Bool = false
    @State private var showAbout: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var modelToDelete: String = ""
    @State private var updateStatus: String = "Check for Updates"
    @State private var updateURL: String? = nil

    private var hasChatOutput: Bool {
        !client.messages.isEmpty || (client.isGenerating && !client.currentStreamingResponse.isEmpty)
    }

    private var hasStatusOnly: Bool {
        client.errorMessage != nil && !hasChatOutput
    }

    private var estimatedStatusLines: CGFloat {
        guard let msg = client.errorMessage else { return 0 }
        let lines = ceil(CGFloat(msg.count) / 45.0)
        return max(1, lines)
    }

    private var calculatedHeight: CGFloat {
        if client.setupState != .ready { return 150 }
        else if showSettings {
            if showAbout { return 360 }
            return client.isDownloadingModel ? 400 : 380
        }
        else if hasChatOutput { return 420 }
        else if hasStatusOnly { return 60 + estimatedStatusLines * 16 + 14 }
        else { return 60 }
    }

    var body: some View {
        VStack(spacing: 0) {
            
            if client.setupState != .ready {
                setupOverlay
            } else if showSettings {
                if showAbout { aboutContent } else { settingsContent }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    TextField("Ask Ari…", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .regular))
                        .focused($isInputFieldFocused)
                        .onSubmit { submitPrompt() }
                        .onChange(of: prompt) { _, newValue in
                            client.resetIdleTimer()
                            if !newValue.isEmpty && client.setupState == .ready {
                                if client.errorMessage?.contains("idle") == true { client.errorMessage = nil }
                                if !client.modelLoaded && !client.isStartingServer && !client.selectedModel.isEmpty {
                                    client.startServer(for: client.selectedModel)
                                }
                            }
                        }

                    if client.isGenerating {
                        Button(action: { client.stopGeneration() }) { Image(systemName: "stop.circle.fill").foregroundColor(.red) }.buttonStyle(.plain)
                    }

                    if !client.messages.isEmpty || !client.currentStreamingResponse.isEmpty {
                        Button("Clear") { client.clearHistory() }.font(.system(size: 12)).foregroundColor(.secondary).buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                if hasStatusOnly {
                    Divider()
                    if let error = client.errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            if error.contains("Loading") || error.contains("Waking") || error.contains("Warming") || error.contains("starting") || error.contains("queued") {
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                            } else if error.hasPrefix("❌") || error.hasPrefix("⚠️") {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.red)
                            } else {
                                Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Text(error).font(.system(size: 12)).foregroundColor(error.hasPrefix("❌") || error.hasPrefix("⚠️") ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }.padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }

                if hasChatOutput {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if let error = client.errorMessage {
                                    Text(error).foregroundColor(error.hasPrefix("❌") || error.hasPrefix("⚠️") ? .red : .blue).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                }

                                ForEach(client.messages) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.isUser ? "You" : client.selectedModel)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(message.isUser ? .blue : .purple)

                                        if message.isUser {
                                            // Padding 0 to ensure flush left
                                            Text(message.text)
                                                .font(.system(size: 13))
                                                .textSelection(.enabled)
                                                .padding(0)
                                        } else {
                                            MarkdownRendererView(text: message.text)

                                            if !client.isGenerating {
                                                HStack(spacing: 10) {
                                                    Button(action: {
                                                        NSPasteboard.general.clearContents()
                                                        NSPasteboard.general.setString(message.text,
                                                            forType: .string
                                                        )
                                                    }) {
                                                        Image(systemName: "doc.on.doc")
                                                            .font(.system(size: 10))
                                                            .foregroundColor(.secondary.opacity(0.5))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .help("Copy as plain text")

                                                    if message.id == client.messages.last(where: { !$0.isUser })?.id {
                                                        Button(action: {
                                                            client.regenerateLast()
                                                        }) {
                                                            Image(systemName: "arrow.clockwise")
                                                                .font(.system(size: 10))
                                                                .foregroundColor(.secondary.opacity(0.5))
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Regenerate response")
                                                    }
                                                }
                                                .padding(.top, 2)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(message.id)
                                }

                                if client.isGenerating && !client.currentStreamingResponse.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(client.selectedModel).font(.system(size: 10, weight: .bold)).foregroundColor(.purple)
                                        
                                        // Feeds the live stream directly into lightweight view - NO LAG/GLITCHES!
                                        LiveStreamingRendererView(text: client.currentStreamingResponse)
                                            
                                    }.frame(maxWidth: .infinity, alignment: .leading).id("streaming")
                                } else if client.isGenerating && client.currentStreamingResponse.isEmpty {
                                    ProgressView().scaleEffect(0.6).frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding(12)
                        }
                        .onChange(of: client.currentStreamingResponse) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: client.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                }
            }

            if client.setupState == .ready {
                Divider()
                HStack(spacing: 0) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if showAbout {
                                showAbout = false
                            } else {
                                showSettings.toggle()
                            }
                        }
                    }) {
                        Image(systemName: (showSettings || showAbout) ? "chevron.left" : "gearshape")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                    Spacer()
                    Button("Exit") { NSApplication.shared.terminate(nil) }
                        .font(.system(size: 10)).foregroundColor(.secondary).buttonStyle(.plain)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(width: 320, height: calculatedHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: calculatedHeight)
        .background(.ultraThinMaterial).cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .onAppear {
            isInputFieldFocused = true
            if client.setupState == .ready && !client.selectedModel.isEmpty && !client.modelLoaded { client.startServer(for: client.selectedModel) }
        }
        .onChange(of: client.setupState) { _, state in
            if state == .ready && !client.selectedModel.isEmpty && !client.modelLoaded { client.startServer(for: client.selectedModel) }
        }
        .onChange(of: client.showSettingsTrigger) { _, show in
            if show { self.showSettings = true; client.showSettingsTrigger = false }
        }
        .onChange(of: client.selectedModel) { oldValue, newValue in
            if client.setupState == .ready && !oldValue.isEmpty && oldValue != newValue { client.clearHistory(); client.restartServer() }
        }
    }
    
    private var setupOverlay: some View {
        VStack(spacing: 12) {
            if client.setupState == .installing || client.setupState == .checking {
                ProgressView().scaleEffect(0.8)
                Text(client.setupState == .checking ? "Checking Environment..." : "Initial Setup in Progress").font(.system(size: 13, weight: .semibold))
            } else if client.setupState == .error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.system(size: 24))
                Text("Setup Failed").font(.system(size: 13, weight: .semibold))
            }
            Text(client.setupProgressText).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 16)
            if client.setupState == .error { Button("Exit") { NSApplication.shared.terminate(nil) }.controlSize(.small) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
    
    private var aboutContent: some View {
        VStack(spacing: 16) {
            Text("About").font(.system(size: 14, weight: .semibold))

            VStack(spacing: 4) {
                if let nsImage = NSImage(named: "AppIcon") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .cornerRadius(14)
                        .padding(.bottom, 4)
                }
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ari")
                    .font(.system(size: 14, weight: .bold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Button(action: {
                if let url = updateURL {
                    NSWorkspace.shared.open(URL(string: url)!)
                    return
                }
                updateStatus = "Checking..."
                Task {
                    do {
                        let reqURL = URL(string: "https://github.com/arinltte/ari/releases/latest")!
                        var request = URLRequest(url: reqURL)
                        request.httpMethod = "HEAD"
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let tag = (response.url?.lastPathComponent ?? "")
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))

                        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"

                        let isNewer = tag.compare(current, options: .numeric) == .orderedDescending

                        if !tag.isEmpty && isNewer {
                            updateStatus = "New Version Released (v\(tag))"
                            updateURL = "https://github.com/arinltte/ari/releases/latest"
                        } else {
                            updateStatus = "Up to Date"
                        }
                    } catch {
                        updateStatus = "Check for Updates"
                    }
                }
            }) {
                Text(updateStatus)
                    .font(.system(size: 11))
                    .foregroundColor(updateURL != nil ? .white : nil)
                    .padding(.horizontal, updateURL != nil ? 8 : 0)
                    .padding(.vertical, updateURL != nil ? 3 : 0)
                    .background(updateURL != nil ? Color.green : Color.clear)
                    .cornerRadius(4)
            }
            .controlSize(.small)
            .disabled(updateStatus == "Checking..." || updateStatus == "Up to Date")

            Divider()
            HStack {
                Text("Menu Bar Icon").font(.system(size: 12, weight: .medium)); Spacer()
                Picker("", selection: $client.menuBarIcon) {
                    Text("⚡ Lightning").tag("bolt.fill")
                    Text("✨ Sparkles").tag("sparkles")
                    Text("🧠 Brain").tag("brain")
                    Text("🪄 Wand").tag("wand.and.stars")
                    Text("💬 Message").tag("message.fill")
                    Text("⚙️ CPU").tag("cpu")
                }.labelsHidden().pickerStyle(.menu)
            }
            Spacer()

            VStack(spacing: 1) {
                Text("2026 Developed by [arinltte](https://github.com/arinltte)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .tint(.blue)

                Text("cjshen00@gmail.com")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .multilineTextAlignment(.center)

            }.padding(14)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { withAnimation { showAbout = true } }) { Image(systemName: "info.circle").font(.system(size: 14)).foregroundColor(.secondary) }.buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Model").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                HStack {
                    if client.availableModels.isEmpty {
                        Text("No models downloaded.").font(.system(size: 11)).foregroundColor(.secondary); Spacer()
                    } else {
                        Picker("", selection: $client.selectedModel) { ForEach(client.availableModels, id: \.self) { model in Text(model).tag(model) } }.labelsHidden().pickerStyle(.menu)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button(action: { client.restartServer() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Restart AI Server").disabled(client.availableModels.isEmpty)
                        Button(action: { NSWorkspace.shared.open(client.modelsDirectory) }) { Image(systemName: "folder") }.buttonStyle(.plain).help("Open Model Folder")
                        Button(action: { modelToDelete = client.selectedModel; showDeleteConfirm = true }) { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete Model").disabled(client.availableModels.isEmpty)
                        .alert("Delete model \"\(modelToDelete)\"?", isPresented: $showDeleteConfirm) {
                            Button("Delete", role: .destructive) { client.deleteModel(modelToDelete) }
                            Button("Cancel", role: .cancel) { }
                        } message: { Text("This action cannot be undone.") }
                    }.foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Idle Timeout").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                Picker("", selection: $client.idleTimeoutSeconds) {
                    Text("15 Seconds").tag(15); Text("30 Seconds").tag(30); Text("2 Minutes").tag(120); Text("5 Minutes").tag(300); Text("Never").tag(0)
                }.labelsHidden().pickerStyle(.menu)
            }

            Toggle("Allow Window Dragging", isOn: $client.isWindowMovable).font(.system(size: 12))
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Download from Hugging Face").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                HStack {
                    TextField("mlx-community/Qwen3.5-2B-MLX-4bit", text: $client.hfRepoId).textFieldStyle(.roundedBorder).font(.system(size: 11)).disabled(client.isDownloadingModel).autocorrectionDisabled()
                        .onChange(of: client.hfRepoId) { _, _ in client.downloadError = nil }
                    if let valid = client.hfRepoValid { Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(valid ? .green : .red).font(.system(size: 13)) }
                    else if !client.hfRepoId.isEmpty { ProgressView().scaleEffect(0.5).frame(width: 14, height: 14) }
                    Button("Download") { client.downloadHuggingFaceModel(id: client.hfRepoId) }.disabled(client.hfRepoValid != true || client.isDownloadingModel).controlSize(.small)
                }
                if let err = client.downloadError {
                    Text(err).font(.system(size: 10, weight: .semibold)).foregroundColor(.red).lineLimit(2)
                } else if client.isDownloadingModel {
                    HStack(spacing: 6) { ProgressView().scaleEffect(0.4).frame(width: 10, height: 10); Text(client.downloadProgressText).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary).lineLimit(1) }.padding(.top, 2)
                }
            }
            .task(id: client.hfRepoId) {
                if client.hfRepoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { client.hfRepoValid = nil; return }
                client.hfRepoValid = nil; try? await Task.sleep(nanoseconds: 700_000_000); guard !Task.isCancelled else { return }
                await client.validateRepo(id: client.hfRepoId)
            }
            Spacer()
        }.padding(14)
    }

    private func submitPrompt() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if client.availableModels.isEmpty { client.errorMessage = "Please download a model in Settings first."; return }
        client.generate(prompt: prompt); prompt = ""
    }
}
