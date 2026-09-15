//
//  ContentView.swift
//  JITTestApp
//
//  Created by Magesh K on 15/09/26.
//  Copyright © 2026 JITTestApp. All rights reserved.
//

import SwiftUI
import AVFoundation

final class BackgroundAudioManager: NSObject, @unchecked Sendable {
    static let shared = BackgroundAudioManager()
    private var player: AVAudioPlayer?
    private var isConfigured = false

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player == nil {
                let silentData = Self.generateSilentWAV()
                player = try AVAudioPlayer(data: silentData)
                player?.numberOfLoops = -1
                player?.volume = 0.01
                player?.prepareToPlay()
            }
            player?.play()
            isConfigured = true
        } catch {
            print("BackgroundAudioManager start failed: \(error)")
        }
    }

    func stop() {
        player?.stop()
        isConfigured = false
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        if type == .ended {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                player?.play()
            } catch {
                print("Failed to reactivate audio session: \(error)")
            }
        }
    }

    private static func generateSilentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples: UInt32 = 8000
        let dataSize: UInt32 = numSamples * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let chunkSize: UInt32 = 36 + dataSize
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var diagnostics: JITDiagnostics?
    @State private var isRunningCheck = false
    @State private var copiedToClipboard = false
    @State private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        statusHeroCard
                        actionsSection
                        diagnosticsSection
                    }
                    .padding()
                }
            }
            .navigationTitle("JIT Status Test")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                BackgroundAudioManager.shared.start()
                runCheck()
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .background:
                    BackgroundAudioManager.shared.start()
                    if backgroundTaskId == .invalid {
                        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "JITWait") {
                            if self.backgroundTaskId != .invalid {
                                UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                                self.backgroundTaskId = .invalid
                            }
                        }
                    }
                case .active:
                    if backgroundTaskId != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskId)
                        backgroundTaskId = .invalid
                    }
                    runCheck()
                default:
                    break
                }
            }
        }
    }

    private var statusHeroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((diagnostics?.isJITActive ?? false) ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .frame(width: 80, height: 80)

                Image(systemName: (diagnostics?.isJITActive ?? false) ? "bolt.shield.fill" : "bolt.slash.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundColor((diagnostics?.isJITActive ?? false) ? .green : .red)
            }
            .padding(.top, 8)

            Text((diagnostics?.isJITActive ?? false) ? "JIT Enabled" : "JIT Inactive")
                .font(.title.bold())
                .foregroundColor(.primary)

            Text((diagnostics?.isJITActive ?? false)
                 ? "Dynamic machine code execution is active and verified via RWX memory."
                 : "Dynamic code generation is blocked. Enable JIT.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
    }

    private var actionsSection: some View {
        VStack(spacing: 8) {
            Button(action: runCheck) {
                HStack(spacing: 8) {
                    if isRunningCheck {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.headline)
                    }

                    Text("Verify JIT Status")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isRunningCheck)

            Button(action: copyDiagnostics) {
                HStack(spacing: 6) {
                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                    Text(copiedToClipboard ? "Copied to Clipboard!" : "Copy Diagnostics")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .foregroundColor(copiedToClipboard ? .green : .accentColor)
                .cornerRadius(10)
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                row(
                    title: "Kernel CS_DEBUGGED",
                    value: (diagnostics?.isCsDebugged ?? false) ? "Enabled (0x10000000)" : "Disabled",
                    status: (diagnostics?.isCsDebugged ?? false) ? .success : .failure
                )
                Divider().padding(.leading, 16)

                if let strategy = diagnostics?.activeStrategy {
                    row(
                        title: "Active Strategy",
                        value: strategy,
                        status: .success
                    )
                    Divider().padding(.leading, 16)
                }

                row(
                    title: "RWX Execution",
                    value: (diagnostics?.mprotectSuccess ?? false) ? "Permitted" : "Blocked",
                    status: (diagnostics?.mprotectSuccess ?? false) ? .success : .failure
                )
                Divider().padding(.leading, 16)

                row(
                    title: "ARM64 Execution",
                    value: diagnostics?.magicReturnValue != nil ? "Returned: \(diagnostics!.magicReturnValue!) (magic 42)" : "Did Not Execute",
                    status: (diagnostics?.executionSuccess ?? false) ? .success : .failure
                )
                Divider().padding(.leading, 16)

                row(
                    title: "Process PID",
                    value: "\(diagnostics?.processId ?? getpid()) (\(diagnostics?.processName ?? ProcessInfo.processInfo.processName))",
                    status: .neutral
                )
                Divider().padding(.leading, 16)

                row(
                    title: "Check Latency",
                    value: String(format: "%.2f ms", diagnostics?.executionDurationMs ?? 0.0),
                    status: .neutral
                )

                if let errorMsg = diagnostics?.errorMessage {
                    Divider().padding(.leading, 16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error Details")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }

    private enum RowStatus {
        case success
        case failure
        case neutral
    }

    private func row(title: String, value: String, status: RowStatus) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 6) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(color(for: status))

                if status == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.footnote)
                } else if status == .failure {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func color(for status: RowStatus) -> Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        case .neutral: return .secondary
        }
    }

    private func copyDiagnostics() {
        var report = "Kernel CS_DEBUGGED: \((diagnostics?.isCsDebugged ?? false) ? "Enabled (0x10000000)" : "Disabled")\n"
        if let strat = diagnostics?.activeStrategy {
            report += "Active Strategy: \(strat)\n"
        }
        report += "RWX Execution: \((diagnostics?.mprotectSuccess ?? false) ? "Permitted" : "Blocked")\n"
        report += "ARM64 Execution: \(diagnostics?.magicReturnValue != nil ? "Returned: \(diagnostics!.magicReturnValue!) (magic 42)" : "Did Not Execute")\n"
        if let err = diagnostics?.errorMessage {
            report += "Errors:\n\(err)\n"
        }
        UIPasteboard.general.string = report
        withAnimation {
            copiedToClipboard = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                self.copiedToClipboard = false
            }
        }
    }

    private func runCheck() {
        isRunningCheck = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = JITChecker.runDiagnostics()
            DispatchQueue.main.async {
                self.diagnostics = result
                self.isRunningCheck = false
            }
        }
    }
}
