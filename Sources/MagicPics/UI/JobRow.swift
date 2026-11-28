import SwiftUI

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
            case .waiting, .working:
                ProgressView().controlSize(.small)
            case let .done(.replaced(out, before, after)):
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
            case let .done(.skipped(reason)):
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
