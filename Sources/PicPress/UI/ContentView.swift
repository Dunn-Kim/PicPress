import SwiftUI

private let savingsText = minSavings.formatted(.percent)

struct ContentView: View {
    @AppStorage("format") private var format = OutputFormat.heic
    @State private var model = BatchModel()
    @State private var path = ""
    @State private var dropTargeted = false
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            if !model.jobs.isEmpty { results }
        }
        .frame(minWidth: 520, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy else { return false }
            Task { await model.scan(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .image], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await model.scan(urls) } }
        }
        .confirmationDialog("이미지 \(model.pending.count)개를 처리할까요?", isPresented: $model.confirming) {
            Button("압축 후 원본 교체", role: .destructive) { model.confirm(format: format) }
        } message: {
            Text("화질 검증을 통과하고 용량이 \(savingsText) 이상 줄어든 파일만 교체합니다. 원본은 휴지통으로 이동합니다.")
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {}
    }

    /// Fixed-height settings; the results list below takes the remaining space and scrolls on its own.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("경로", text: $path, prompt: Text("폴더 경로 (예: ~/Pictures)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(scanPath)
                Button("선택…") { picking = true }
                Button("시작", action: scanPath)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
            Picker("형식", selection: $format) {
                ForEach(OutputFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            VStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(model.running ? "처리 중…" : "폴더나 사진을 창에 끌어다 놓아도 됩니다")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(dropTargeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5])))
            Text("하위 폴더까지 원본 해상도 그대로 다시 압축하고, 화질 검증을 통과하면서 용량이 \(savingsText) 이상 줄어든 파일만 교체합니다. 원본은 휴지통으로 이동하며 촬영일·위치 등 메타데이터는 유지됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .disabled(model.running)
    }

    private var results: some View {
        VStack(spacing: 0) {
            Divider()
            Text(model.summary)
                .font(.headline)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            List(model.visibleJobs) { JobRow(job: $0) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func scanPath() {
        Task { await model.scan(path: path) }
    }
}
