import SwiftUI

@main
struct PicPressApp: App {
    var body: some Scene {
        Window("PicPress", id: "main") { ContentView() }
    }
}

struct Job: Identifiable {
    enum Status {
        case waiting, working
        case replaced(URL, before: Int, after: Int)
        case skipped(String)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .waiting, .working: false
            default: true
            }
        }

        var isWaiting: Bool {
            if case .waiting = self { true } else { false }
        }

        var saved: Int {
            switch self {
            case let .replaced(_, before, after): before - after
            default: 0
            }
        }
    }

    let id = UUID()
    let src: URL
    var status = Status.waiting
}

// ponytail: fixed worker count; each holds a decoded image plus two RGBA copies (~0.6 GB for 48 MP).
// Make it adaptive to free memory if huge panoramas OOM.
private let workers = min(4, ProcessInfo.processInfo.activeProcessorCount)

struct ContentView: View {
    @AppStorage("format") private var format = OutputFormat.heic
    @State private var path = ""
    @State private var jobs: [Job] = []
    @State private var pending: [URL] = []
    @State private var confirming = false
    @State private var notice: String?
    @State private var running = false
    @State private var dropTargeted = false
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !jobs.isEmpty { results }
        }
        .frame(minWidth: 520, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            guard !running, !confirming else { return false }
            prepare(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { prepare(urls) }
        }
        .confirmationDialog("이미지 \(pending.count)개를 처리할까요?", isPresented: $confirming) {
            Button("압축 후 원본 교체", role: .destructive) { process(pending) }
        } message: {
            Text("화질 검증을 통과하고 용량이 10% 이상 줄어든 파일만 교체합니다. 원본은 휴지통으로 이동합니다.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {}
    }

    /// Fixed-height settings; the results list below takes the remaining space and scrolls on its own.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("경로", text: $path, prompt: Text("폴더 경로 (예: ~/Pictures)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startFromPath)
                Button("선택…") { picking = true }
                Button("시작", action: startFromPath)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
            Picker("형식", selection: $format) {
                ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(running ? "처리 중…" : "폴더나 사진을 창에 끌어다 놓아도 됩니다")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(dropTargeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
            Text("하위 폴더까지 원본 해상도 그대로 다시 압축하고, 화질 검증을 통과하면서 용량이 10% 이상 줄어든 파일만 교체합니다. 원본은 휴지통으로 이동하며 촬영일·위치 등 메타데이터는 유지됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .disabled(running)
    }

    /// Lazy list, newest first, so progress stays in view without scrolling; queued files are hidden.
    private var results: some View {
        VStack(spacing: 0) {
            Divider()
            Text(summary)
                .font(.headline)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            List(jobs.filter { !$0.status.isWaiting }.reversed()) { JobRow(job: $0) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var summary: String {
        let done = jobs.filter(\.status.isFinished).count
        let saved = jobs.reduce(0) { $0 + $1.status.saved }
        return "\(done)/\(jobs.count) 완료 · \(saved.formatted(.byteCount(style: .file))) 절감"
    }

    private func startFromPath() {
        let cleaned = path
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            .replacingOccurrences(of: "\\ ", with: " ") // pasted from Terminal
        let url = URL(filePath: (cleaned as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            notice = "경로를 찾을 수 없습니다: \(cleaned)"
            return
        }
        prepare([url])
    }

    private func prepare(_ urls: [URL]) {
        guard !running, !confirming else { return } // one batch at a time; `pending` is frozen while confirming
        running = true
        Task {
            let files = await expand(urls)
            running = false
            if files.isEmpty {
                notice = "이미지 파일이 없습니다"
            } else {
                pending = files
                confirming = true
            }
        }
    }

    private func process(_ files: [URL]) {
        guard !running else { return }
        let fmt = format
        jobs = files.map { Job(src: $0) } // a new batch starts a fresh list, so indices below stay valid
        let batch = jobs
        running = true
        Task {
            await withTaskGroup(of: (Int, Job.Status).self) { group in
                for (i, job) in batch.enumerated() {
                    if i >= workers, let result = await group.next() { jobs[result.0].status = result.1 }
                    jobs[i].status = .working
                    group.addTask { (i, await run(job.src, format: fmt)) }
                }
                for await (done, status) in group { jobs[done].status = status }
            }
            running = false
        }
    }
}

@concurrent
private func expand(_ urls: [URL]) async -> [URL] {
    imageFiles(in: urls)
}

@concurrent
private func run(_ src: URL, format: OutputFormat) async -> Job.Status {
    do {
        switch try optimize(src, format: format) {
        case let .replaced(url, before, after): return .replaced(url, before: before, after: after)
        case let .skipped(reason): return .skipped(reason)
        }
    } catch {
        return .failed(error.localizedDescription)
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack {
            Text(job.src.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.src.path)
            Spacer()
            switch job.status {
            case .waiting:
                Text("대기").foregroundStyle(.tertiary)
            case .working:
                ProgressView().controlSize(.small)
            case let .replaced(out, before, after):
                Text("\(before.formatted(.byteCount(style: .file))) → \(after.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text((Double(after) / Double(before) - 1).formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(.green)
                    .monospacedDigit()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Finder에서 보기")
            case let .skipped(reason):
                Text(reason).foregroundStyle(.secondary)
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            }
        }
    }
}
