import SwiftUI
import AppKit
import QuickLook
import QuickLookThumbnailing

/// Recorded files in Recording Settings: thumbnail on the left of the entry, and Show in Finder / Quick Look
/// from the right-click menu (and the editor). A file that was moved or deleted gets a message, not a crash.
enum RecordedFile {
    static func exists(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// Selects the file in Finder. Returns false when it is gone (the caller shows `MissingFileAlert`).
    @discardableResult
    static func showInFinder(_ path: String) -> Bool {
        guard exists(path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    /// Opens the folder the file was in (used when the file itself is gone).
    static func openFolder(of path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
    }
}

/// State behind the Show in Finder / Quick Look actions of one view: the Quick Look selection and the
/// "file not found" alert. Attach with `.recordedFileActions(_:)`.
final class RecordedFileActions: ObservableObject {
    @Published var quickLook: URL?
    @Published var missing: String?
    /// Every existing file of the output, so the arrow keys in Quick Look move between them.
    @Published var quickLookItems: [URL] = []

    func showInFinder(_ path: String) {
        if !RecordedFile.showInFinder(path) { missing = path }
    }

    func preview(_ path: String, among paths: [String]) {
        guard RecordedFile.exists(path) else { missing = path; return }
        quickLookItems = paths.filter(RecordedFile.exists).map { URL(fileURLWithPath: $0) }
        let url = URL(fileURLWithPath: path)
        if !quickLookItems.contains(url) { quickLookItems.append(url) }
        quickLook = url
    }
}

private struct RecordedFileActionsModifier: ViewModifier {
    @ObservedObject var actions: RecordedFileActions

    func body(content: Content) -> some View {
        content
            .quickLookPreview($actions.quickLook, in: actions.quickLookItems)
            .alert(L("파일을 찾을 수 없음"),
                   isPresented: Binding(get: { actions.missing != nil }, set: { if !$0 { actions.missing = nil } }),
                   presenting: actions.missing) { path in
                Button(L("폴더 열기")) { RecordedFile.openFolder(of: path) }
                Button(L("확인"), role: .cancel) {}
            } message: { path in
                Text(Lf("%@ 파일이 옮겨졌거나 삭제되었습니다.", RecordedFile.name(path)))
            }
    }
}

extension View {
    func recordedFileActions(_ actions: RecordedFileActions) -> some View {
        modifier(RecordedFileActionsModifier(actions: actions))
    }
}

/// Right-click menu items for a record output's files: the newest file, then earlier ones (splits, earlier takes).
struct RecordedFileMenuItems: View {
    @ObservedObject var output: OutputChannel
    let actions: RecordedFileActions

    var body: some View {
        if output.config.kind == .record, !output.lastFile.isEmpty {
            let files = output.recentFiles.isEmpty ? [output.lastFile] : output.recentFiles
            items(for: output.lastFile, files: files)
            let earlier = files.filter { $0 != output.lastFile }.reversed()
            if !earlier.isEmpty {
                Menu(L("이전 녹화 파일")) {
                    ForEach(Array(earlier), id: \.self) { path in
                        Menu(RecordedFile.name(path)) { items(for: path, files: files) }
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func items(for path: String, files: [String]) -> some View {
        Button(L("Finder에서 보기")) { actions.showInFinder(path) }
        // The file being written has no index yet, so Quick Look can't play it until recording stops.
        Button(L("훑어보기")) { actions.preview(path, among: files) }
            .disabled(output.running && path == output.lastFile)
    }
}

/// Small picture of a recorded file (Quick Look thumbnail), or the output's symbol while there is none.
struct RecordingThumbnail: View {
    let path: String
    let running: Bool
    let symbol: String

    @State private var image: NSImage?

    static let size = CGSize(width: 48, height: 27)

    init(path: String, running: Bool, symbol: String) {
        self.path = path
        self.running = running
        self.symbol = symbol
        _image = State(initialValue: Self.cached(path))   // no flicker when the sheet opens again
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            } else {
                Image(systemName: symbol)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .help(path.isEmpty ? "" : RecordedFile.name(path))
        // A file still being written usually has no thumbnail yet; try again once recording stops.
        .task(id: "\(path)|\(running)") { image = await Self.thumbnail(for: path) }
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// Cache key changes when the file is rewritten (or still growing), so a stale picture is never shown.
    private static func key(_ path: String) -> NSString? {
        guard RecordedFile.exists(path), let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(stamp)|\(bytes)" as NSString
    }

    static func cached(_ path: String) -> NSImage? {
        key(path).flatMap { cache.object(forKey: $0) }
    }

    static func thumbnail(for path: String) async -> NSImage? {
        guard let key = key(path) else { return nil }
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                                   size: CGSize(width: Self.size.width * 2, height: Self.size.height * 2),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: key)
        return rep.nsImage
    }
}
