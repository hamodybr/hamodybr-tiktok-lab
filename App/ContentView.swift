import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var model = LabModel()
    @State private var importingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var fileSlot: VideoSlot = .original
    private let cyan = Color(red: 0.15, green: 0.91, blue: 0.89)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    importPanel
                    if model.busy {
                        VStack(alignment: .leading, spacing: 10) {
                            if let name = model.selectedFileName { Text(name).font(.caption).lineLimit(2) }
                            HStack { Text(model.status).font(.subheadline); Spacer(); Text("\(Int(model.progress * 100))%").font(.caption.monospacedDigit()) }
                            ProgressView(value: model.progress).tint(cyan).accessibilityIdentifier("import-progress")
                            Button("إلغاء الفحص", role: .cancel) { model.cancel() }.accessibilityIdentifier("cancel-import")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding().card()
                    } else {
                        Text(model.status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("lab-status")
                    }
                    if let report = model.current {
                        summary(report)
                        timing(report)
                        observations(report)
                        atoms(report)
                    } else if !model.busy { emptyState }
                    if let original = model.original, let tiktok = model.tiktok { comparison(original, tiktok) }
                    if model.original != nil || model.tiktok != nil || model.hasFailure { exportPanel }
                    Text("V0.2 • الفحص محلي على الآيفون. معلومات الملف تساعدنا على التشخيص؛ لا تضمن جودة تيكتوك أو تفسر وحدها تقطيع الشبكة.")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom)
                }
                .padding(20)
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.07))
            .navigationTitle("TikTok Lab")
            .navigationBarTitleDisplayMode(.inline)
            .tint(cyan)
            .fullScreenCover(isPresented: $importingFile) {
                NativeVideoPicker(onPick: { url in
                    importingFile = false
                    model.beginFileImport(url, slot: fileSlot)
                }, onCancel: {
                    importingFile = false
                    model.pickerCancelled()
                }, onError: { message in
                    importingFile = false
                    model.error = message
                }).ignoresSafeArea()
            }
            .onChange(of: photo) { item in
                if let item {
                    let slot = model.selected
                    model.beginPhotoImport(item, slot: slot)
                    photo = nil
                }
            }
            .alert("تعذر إكمال العملية", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("حسنًا") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HAMODYBR").font(.caption.bold()).tracking(4).foregroundStyle(cyan)
            Text("اعرف شنو تغيّر بالفيديو").font(.title2.bold())
            Text("الأصل ← نسخة تيكتوك ← مقارنة واضحة").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("الفيديو", selection: $model.selected) {
                ForEach(VideoSlot.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.busy)
            HStack(spacing: 12) {
                Button {
                    fileSlot = model.selected
                    model.pickerOpened()
                    importingFile = true
                } label: { Label("من الملفات", systemImage: "folder").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("import-files")
                PhotosPicker(selection: $photo, matching: .videos, preferredItemEncoding: .current) {
                    Label("من الصور", systemImage: "photo").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }.disabled(model.busy)
            HStack {
                Button { model.sample() } label: { Label("جرّب فيديو تجريبي", systemImage: "play.circle") }
                    .font(.caption).disabled(model.busy).accessibilityIdentifier("import-sample")
                Spacer()
                if model.current != nil {
                    Button("مسح", role: .destructive) { model.clearCurrent() }.font(.caption).disabled(model.busy)
                }
            }
            Text("لملفات Replica وبنية MP4 الدقيقة، استخدم «الملفات»؛ تصدير مكتبة الصور قد يعطي ملفًا مختلفًا. نسخة تيكتوك تضيفها بعد تنزيلها بنفسك.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().card()
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 46)).foregroundStyle(cyan)
            Text("فيديوك هو نقطة البداية").font(.headline)
            Text("نقرأ الجودة والتوقيت والمسارات ونبحث عن اختلاف عدد العينات ومدة 0:00.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal).card()
    }
    private func summary(_ r: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(r.label, systemImage: "film").font(.headline)
            Text(r.mp4.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(2).accessibilityIdentifier("report-file-name")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metric("الدقة", r.resolution)
                metric("FPS", r.fpsText)
                metric("الحجم", ByteCountFormatter.string(fromByteCount: Int64(r.mp4.fileSize), countStyle: .file))
                metric("المدة / Apple", seconds(r.appleDuration))
            }
            row("Codec", r.mp4.tracks.filter { $0.kind == "vide" }.map(\.codec).joined(separator: ", "))
            row("Video bitrate", bitrate(r.video?.estimatedBitrate))
            row("الصوت", r.mp4.tracks.filter { $0.kind == "soun" }.map(\.codec).joined(separator: ", "))
            row("Audio sample rate", r.audio?.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "غير متاح")
            row("Transfer function", r.video?.transferFunction ?? "غير متاح")
            row("Color primaries", r.video?.colorPrimaries ?? "غير متاح")
            row("Color matrix", r.video?.ycbcrMatrix ?? "غير متاح")
            Text("bitrate تقديري، وFPS قيمة اسمية أو متوسط. بيانات الألوان لا تثبت وحدها وجود Dolby Vision.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().card()
    }
    private func timing(_ r: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("التوقيت وبنية الملف", systemImage: "clock").font(.headline)
            row("مدة mvhd", seconds(r.mp4.seconds))
            row("Fast start", r.mp4.fastStart.map { $0 ? "نعم" : "لا" } ?? "غير متاح")
            Text(r.mp4.topLevelOrder).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
            ForEach(r.mp4.tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    Text("المسار \(track.index) • \(track.kind) / \(track.codec)").font(.subheadline.bold())
                    row("مدة mdhd", seconds(track.seconds))
                    row("مدة tkhd", track.headerDurationKnown && r.mp4.movieTimescale > 0 ? seconds(Double(track.headerDuration) / Double(r.mp4.movieTimescale)) : "غير متاح")
                    row("stsz / stz2 samples", count(track.sampleCount))
                    row("stts samples", count(track.timingSampleCount))
                    row("ctts samples", count(track.compositionSampleCount))
                    row("Timescale", String(track.timescale))
                }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding().card()
    }
    private func observations(_ r: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ملاحظات الفحص", systemImage: r.warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline).foregroundStyle(r.warnings.isEmpty ? cyan : .orange)
            if r.warnings.isEmpty {
                Text("لم تظهر اختلافات في الفحوص المنفّذة. هذا فحص للرؤوس والتوقيت؛ ليس تحققًا كاملًا من كل عينة.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(r.warnings.enumerated()), id: \.offset) { _, warning in
                    Text("• " + warning).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding().card()
    }
    private func atoms(_ r: VideoAnalysis) -> some View {
        DisclosureGroup("MP4 atoms • \(r.mp4.atoms.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(r.mp4.atoms.prefix(300)) { atom in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atom.path).font(.system(.caption, design: .monospaced))
                        Text("offset \(atom.offset) · size \(atom.size)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.leading, CGFloat(atom.depth) * 8)
                }
                if r.mp4.atoms.count > 300 { Text("باقي العناصر موجودة في تقرير JSON").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                .environment(\.layoutDirection, .leftToRight)
        }.font(.subheadline.bold()).padding().card()
    }
    private func comparison(_ a: VideoAnalysis, _ b: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("الأصل × نسخة تيكتوك", systemImage: "arrow.left.arrow.right").font(.headline)
            HStack { Text("الخاصية"); Spacer(); Text("الأصل"); Spacer(); Text("تيكتوك") }.font(.caption).foregroundStyle(.secondary)
            compareRow("الدقة", a.resolution, b.resolution)
            compareRow("FPS", a.fpsText, b.fpsText)
            compareRow("المدة", seconds(a.duration), seconds(b.duration))
            compareRow("bitrate", bitrate(a.video?.estimatedBitrate), bitrate(b.video?.estimatedBitrate))
            compareRow("Codec", a.mp4.tracks.first(where: { $0.kind == "vide" })?.codec ?? "—", b.mp4.tracks.first(where: { $0.kind == "vide" })?.codec ?? "—")
            Divider()
            let same = a.mediaSHA256 == b.mediaSHA256
            Text(same ? "بصمة بيانات mdat متطابقة" : "بصمة بيانات mdat مختلفة")
                .font(.subheadline.bold()).foregroundStyle(same ? cyan : .orange)
            Text(same ? "بايتات بيانات الوسائط متطابقة، بما فيها الصوت؛ قد تختلف معلومات التشغيل خارج mdat." : "تغيّرت بيانات الوسائط. لا تحدد البصمة وحدها هل التغيير في الفيديو أو الصوت، ولا تقيس فقدان التفاصيل.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("SHA-256") {
                Text("Original: \(a.mediaSHA256)\nTikTok: \(b.mediaSHA256)")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight).padding(.top, 8)
            }
        }.padding().card()
    }
    private var exportPanel: some View {
        VStack(spacing: 12) {
            Button { model.export() } label: {
                Label("جهّز تقرير المقارنة", systemImage: "doc.text").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(model.busy)
            if let url = model.exportURL {
                ShareLink(item: url) { Label("شارك تقرير JSON", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            if let video = model.currentVideoURL {
                ShareLink(item: video) { Label("شارك نسخة الفيديو المستوردة", systemImage: "film") }
                    .buttonStyle(.bordered).disabled(model.busy)
            }
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).minimumScaleFactor(0.65).lineLimit(1)
                .environment(\.layoutDirection, .leftToRight)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value.isEmpty ? "غير متاح" : value).font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
    private func compareRow(_ label: String, _ a: String, _ b: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Text(a).frame(maxWidth: .infinity)
            Text(b).foregroundStyle(a == b ? .primary : cyan).frame(maxWidth: .infinity)
        }.font(.system(.caption, design: .monospaced))
    }
    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f s", $0) } ?? "غير متاح"
    }
    private func bitrate(_ value: Float?) -> String {
        guard let value, value > 0, value.isFinite else { return "غير متاح" }
        return String(format: "%.2f Mb/s", value / 1_000_000)
    }
    private func count(_ value: UInt64?) -> String { value.map(String.init) ?? "—" }
}

private struct NativeVideoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: NativeVideoPicker
        private var completed = false
        init(parent: NativeVideoPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            guard let url = urls.first else { parent.onError("لم يرجع منتقي الملفات فيديو. أعد الاختيار."); return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            parent.onCancel()
        }
    }
}

private extension View {
    func card() -> some View {
        background(Color(red: 0.075, green: 0.09, blue: 0.13), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.055), lineWidth: 1))
    }
}
