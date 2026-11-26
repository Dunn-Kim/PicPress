import Foundation
import Observation

struct Job: Identifiable {
    enum Status {
        case waiting, working
        case done(Outcome)
        case failed(String)

        var isWaiting: Bool {
            if case .waiting = self { true } else { false }
        }

        var isFinished: Bool {
            switch self {
            case .waiting, .working: false
            case .done, .failed: true
            }
        }

        var saved: Int {
            if case let .done(.replaced(_, before, after)) = self { before - after } else { 0 }
        }
    }

    let id = UUID()
    let src: URL
    var status = Status.waiting
}

// ponytail: fixed worker count; each holds a decoded image plus two RGBA copies (~0.6 GB for 48 MP).
// Make it adaptive to free memory if huge panoramas OOM.
private let workers = min(4, ProcessInfo.processInfo.activeProcessorCount)

/// One batch at a time: scan → user confirms → optimize every file with a bounded worker pool.
@MainActor @Observable
final class BatchModel {
    private(set) var jobs: [Job] = []
    private(set) var pending: [URL] = []
    private(set) var running = false
    var confirming = false
    var notice: String?

    private let discard: @Sendable (URL) throws -> URL?

    init(discard: @escaping @Sendable (URL) throws -> URL? = moveToTrash) {
        self.discard = discard
    }

    var isBusy: Bool { running || confirming }

    /// Newest first, so progress stays in view without scrolling; queued files are hidden.
    var visibleJobs: [Job] { jobs.filter { !$0.status.isWaiting }.reversed() }

    var summary: String {
        let done = jobs.filter(\.status.isFinished).count
        let saved = jobs.reduce(0) { $0 + $1.status.saved }
        return "\(done)/\(jobs.count) 완료 · \(saved.formatted(.byteCount(style: .file))) 절감"
    }

    func scan(path: String) async {
        guard let url = parsePath(path) else {
            notice = "경로를 찾을 수 없습니다: \(path)"
            return
        }
        await scan([url])
    }

    /// Finds images under `urls`, then asks for confirmation (`pending` stays frozen while confirming).
    func scan(_ urls: [URL]) async {
        guard !isBusy else { return }
        running = true
        let files = await findImages(urls)
        running = false
        if files.isEmpty {
            notice = "이미지 파일이 없습니다"
        } else {
            pending = files
            confirming = true
        }
    }

    func process(format: OutputFormat) async {
        guard !running else { return }
        jobs = pending.map { Job(src: $0) } // a new batch starts a fresh list, so indices below stay valid
        pending = []
        running = true
        let batch = jobs, discard = discard
        await withTaskGroup(of: (Int, Job.Status).self) { group in
            for (i, job) in batch.enumerated() {
                if i >= workers, let result = await group.next() { jobs[result.0].status = result.1 }
                jobs[i].status = .working
                group.addTask { (i, await optimizeJob(job.src, format: format, discard: discard)) }
            }
            for await (i, status) in group { jobs[i].status = status }
        }
        running = false
    }
}

@concurrent
private func findImages(_ urls: [URL]) async -> [URL] {
    imageFiles(in: urls)
}

@concurrent
private func optimizeJob(_ src: URL, format: OutputFormat, discard: @Sendable (URL) throws -> URL?) async -> Job.Status {
    do {
        return .done(try optimize(src, format: format, discard: discard))
    } catch {
        return .failed(error.localizedDescription)
    }
}
