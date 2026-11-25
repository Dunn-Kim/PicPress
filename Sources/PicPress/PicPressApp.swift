import SwiftUI

@main
struct PicPressApp: App {
    var body: some Scene {
        Window("PicPress", id: "main") { ContentView() }
    }
}

struct Job: Identifiable {
    enum Status {
        case working
        case done(URL, before: Int, after: Int)
        case failed(String)
    }

    let id = UUID()
    let src: URL
    var status = Status.working
}

struct ContentView: View {
    @AppStorage("format") private var format = OutputFormat.jpeg
    @AppStorage("quality") private var quality = 0.7
    @AppStorage("maxPixel") private var maxPixel = 0 // 0 = keep original size
    @State private var jobs: [Job] = []
    @State private var dropTargeted = false
    @State private var picking = false

    var body: some View {
        Form {
            Section {
                Picker("형식", selection: $format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Slider(value: $quality, in: 0.1...1, step: 0.05) {
                    Text("품질 \(quality.formatted(.percent.precision(.fractionLength(0))))")
                }
                Picker("최대 크기", selection: $maxPixel) {
                    Text("원본 유지").tag(0)
                    ForEach([4096, 2560, 1920, 1280], id: \.self) { Text(verbatim: "\($0)px").tag($0) }
                }
            }

            Section {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("사진을 창에 끌어다 놓으세요")
                    Button("파일 선택…") { picking = true }
                }
                .frame(maxWidth: .infinity, minHeight: 140)
                .background(dropTargeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
            } footer: {
                Text("원본은 그대로 두고 같은 폴더에 `이름-picpress` 파일로 저장합니다. 위치 정보 등 메타데이터는 제거됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !jobs.isEmpty {
                Section {
                    ForEach(jobs) { JobRow(job: $0) }
                } header: {
                    HStack {
                        Text("결과")
                        Spacer()
                        Button("목록 지우기") { jobs.removeAll() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .dropDestination(for: URL.self) { urls, _ in
            start(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { start(urls) }
        }
    }

    private func start(_ urls: [URL]) {
        let f = format, q = quality, m = maxPixel == 0 ? nil : maxPixel
        for url in urls {
            let job = Job(src: url)
            jobs.insert(job, at: 0)
            // ponytail: one task per file; the cooperative pool caps parallelism at core count,
            // so peak memory ≈ cores × one decoded image. Add a semaphore if huge batches OOM.
            Task {
                let status = await run(url, format: f, quality: q, maxPixel: m)
                if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].status = status }
            }
        }
    }
}

@concurrent
private func run(_ src: URL, format: OutputFormat, quality: Double, maxPixel: Int?) async -> Job.Status {
    do {
        let out = try compress(src, quality: quality, maxPixel: maxPixel, format: format)
        return .done(out, before: fileSize(src), after: fileSize(out))
    } catch {
        return .failed(error.localizedDescription)
    }
}

private func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack {
            Text(job.src.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            switch job.status {
            case .working:
                ProgressView().controlSize(.small)
            case let .done(out, before, after):
                let change = before > 0 ? Double(after) / Double(before) - 1 : 0
                Text("\(before.formatted(.byteCount(style: .file))) → \(after.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
                    .foregroundStyle(change < 0 ? .green : .red)
                    .monospacedDigit()
                    .help(change < 0 ? "" : "원본보다 커졌습니다. 품질이나 크기를 낮춰보세요.")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Finder에서 보기")
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}
