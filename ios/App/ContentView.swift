import SwiftUI

/// 主 App 首頁：負責下載/管理本地端模型（Keyboard Extension 不會做這件事），
/// 並顯示鍵盤啟用步驟。這個畫面同時也是讓 App 保持存活以接收
/// Keyboard Extension 背景推理請求的最簡單方式。
struct ContentView: View {
    @ObservedObject var processingService: AudioProcessingService

    @State private var whisperProgress = ModelProgress(downloadedBytes: 0, totalBytes: 0, state: .notStarted, error: nil)
    @State private var llmProgress = ModelProgress(downloadedBytes: 0, totalBytes: 0, state: .notStarted, error: nil)
    @State private var pollTimer: Timer?

    private var modelsReady: Bool {
        whisperProgress.state == .ready && llmProgress.state == .ready
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("EchoWrite")
                .font(.largeTitle.bold())

            if modelsReady {
                Label("本地端模型已就緒", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    modelRow(name: "語音辨識模型 (Whisper)", progress: whisperProgress)
                    modelRow(name: "語意潤飾模型 (Qwen)", progress: llmProgress)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if processingService.isProcessing {
                Label("正在處理鍵盤送出的錄音...", systemImage: "waveform")
                    .foregroundStyle(.blue)
            }

            if let error = processingService.lastError {
                Text("上次處理發生錯誤：\(error)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            VStack(spacing: 6) {
                Text("1. 至「設定 > 一般 > 鍵盤 > 鍵盤」新增 EchoWrite")
                Text("2. 開啟「允許完全取用」（存取共享模型與麥克風必須）")
                Text("3. 讓 EchoWrite 保持在背景執行，才能即時處理鍵盤請求")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .padding()
        .onAppear(perform: start)
        .onDisappear { pollTimer?.invalidate() }
    }

    private func modelRow(name: String, progress: ModelProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text(stateLabel(progress.state)).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: downloadFraction(progress))
        }
    }

    private func stateLabel(_ state: ModelDownloadState) -> String {
        switch state {
        case .notStarted: return "等待中"
        case .downloading: return "下載中"
        case .verifying: return "校驗中"
        case .ready: return "已就緒"
        case .failed: return "失敗"
        }
    }

    private func downloadFraction(_ progress: ModelProgress) -> Double {
        guard progress.totalBytes > 0 else { return progress.state == .ready ? 1 : 0 }
        return Double(progress.downloadedBytes) / Double(progress.totalBytes)
    }

    private func start() {
        EchoWriteShared.configureSharedModelDirectory()
        refresh()
        if whisperProgress.state != .ready {
            ewStartModelDownload(kind: .whisper)
        }
        if llmProgress.state != .ready {
            ewStartModelDownload(kind: .llm)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refresh()
        }
    }

    private func refresh() {
        whisperProgress = ewGetModelDownloadProgress(kind: .whisper)
        llmProgress = ewGetModelDownloadProgress(kind: .llm)
    }
}

#Preview {
    ContentView(processingService: AudioProcessingService())
}
