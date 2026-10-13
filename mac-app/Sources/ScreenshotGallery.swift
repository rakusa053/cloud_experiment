import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App

@main
struct ScreenshotGalleryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library()

    var body: some Scene {
        Window("スクショギャラリー", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 520, minHeight: 400)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("フォルダを変更…") { library.chooseFolder() }
                    .keyboardShortcut("o")
                Button("スクリーンショットの保存先に戻す") { library.useSystemFolder() }
                Divider()
                Button("再読み込み") { library.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Model

struct Photo: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var folder: URL
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var loaded = false

    private static let customFolderKey = "customFolder"
    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.customFolderKey),
           FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = Self.systemScreenshotFolder()
        }
        reload()
        startWatching()
        // 権限ダイアログから戻ったときなどに読み直す
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// ⌘⇧5 の「オプション > 保存先」で設定されたフォルダ（未設定ならデスクトップ）
    static func systemScreenshotFolder() -> URL {
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var isUsingSystemFolder: Bool {
        UserDefaults.standard.string(forKey: Self.customFolderKey) == nil
    }

    func reload() {
        let folder = folder
        Task {
            let result = await Task.detached(priority: .userInitiated) { Library.scan(folder) }.value
            guard folder == self.folder else { return }
            switch result {
            case .success(let list):
                if list != photos { photos = list }
                errorMessage = nil
            case .failure(let error):
                photos = []
                errorMessage = error.localizedDescription
            }
            loaded = true
        }
    }

    nonisolated static func scan(_ folder: URL) -> Result<[Photo], Error> {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            let photos = urls.compactMap { url -> Photo? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let type = values.contentType, type.conforms(to: .image)
                else { return nil }
                return Photo(url: url, date: values.creationDate ?? values.contentModificationDate ?? .distantPast)
            }
            return .success(photos.sorted { $0.date > $1.date })
        } catch {
            return .failure(error)
        }
    }

    // フォルダの変化を監視して、新しいスクショをすぐ反映する
    private func startWatching() {
        source?.cancel()
        source = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
            // 書き込み途中のファイルがあっても後で正しく表示されるよう、もう一度読む
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func setFolder(_ url: URL, custom: Bool) {
        if custom {
            UserDefaults.standard.set(url.path, forKey: Self.customFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.customFolderKey)
        }
        folder = url
        photos = []
        loaded = false
        reload()
        startWatching()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "このフォルダを表示"
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url, custom: true)
        }
    }

    func useSystemFolder() {
        setFolder(Self.systemScreenshotFolder(), custom: false)
    }

    func trash(_ photo: Photo) {
        do {
            try FileManager.default.trashItem(at: photo.url, resultingItemURL: nil)
            photos.removeAll { $0 == photo }
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Actions

enum PhotoActions {
    static func copy(_ photo: Photo) {
        guard let image = NSImage(contentsOf: photo.url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    static func revealInFinder(_ photo: Photo) {
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    static func open(_ photo: Photo) {
        NSWorkspace.shared.open(photo.url)
    }
}

// MARK: - Thumbnails

final class ImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum ImageLoader {
    private static let cache: NSCache<NSString, ImageBox> = {
        let c = NSCache<NSString, ImageBox>()
        c.countLimit = 600
        return c
    }()

    static func thumbnail(for photo: Photo, maxPixel: Int) async -> CGImage? {
        let key = "\(photo.url.path)|\(photo.date.timeIntervalSince1970)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let url = photo.url
        let image = await Task.detached(priority: .utility) { ImageLoader.load(url, maxPixel: maxPixel) }.value
        if let image { cache.setObject(ImageBox(image), forKey: key) }
        return image
    }

    static func full(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
        }.value
    }

    private static func load(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Gallery

struct DaySection: Identifiable {
    let id: Date
    let title: String
    let photos: [Photo]
}

func makeSections(_ photos: [Photo]) -> [DaySection] {
    let cal = Calendar.current
    var result: [DaySection] = []
    var currentDay: Date?
    var bucket: [Photo] = []
    func flush() {
        if let day = currentDay, !bucket.isEmpty {
            result.append(DaySection(id: day, title: dayTitle(day), photos: bucket))
        }
    }
    for photo in photos {
        let day = cal.startOfDay(for: photo.date)
        if day != currentDay {
            flush()
            currentDay = day
            bucket = []
        }
        bucket.append(photo)
    }
    flush()
    return result
}

func dayTitle(_ day: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(day) { return "今日" }
    if cal.isDateInYesterday(day) { return "昨日" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ja_JP")
    f.dateFormat = cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "M月d日(E)" : "yyyy年M月d日(E)"
    return f.string(from: day)
}

struct ContentView: View {
    @EnvironmentObject private var library: Library
    @AppStorage("thumbnailSize") private var thumbSize: Double = 170
    @State private var selected: URL?

    var body: some View {
        ZStack {
            gallery
            if selected != nil {
                ViewerView(selected: $selected)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selected != nil)
        .navigationTitle(library.folder.lastPathComponent)
        .navigationSubtitle(library.photos.isEmpty ? "" : "\(library.photos.count) 枚")
        .toolbar {
            ToolbarItemGroup {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").imageScale(.small)
                    Slider(value: $thumbSize, in: 90...360).frame(width: 110)
                    Image(systemName: "square.grid.2x2").imageScale(.medium)
                }
                .foregroundStyle(.secondary)
                .help("サムネイルの大きさ")
                Button {
                    NSWorkspace.shared.open(library.folder)
                } label: {
                    Label("Finderで開く", systemImage: "folder")
                }
                .help("このフォルダをFinderで開く")
                Button {
                    library.chooseFolder()
                } label: {
                    Label("フォルダを変更", systemImage: "folder.badge.gearshape")
                }
                .help("表示するフォルダを変更")
            }
        }
    }

    @ViewBuilder private var gallery: some View {
        if let message = library.errorMessage {
            MessageView(
                symbol: "lock.fill",
                title: "フォルダを読み込めませんでした",
                text: "\(library.folder.path)\n\n\(message)\n\n「システム設定 › プライバシーとセキュリティ › ファイルとフォルダ」で、このアプリのアクセスを許可してください。"
            ) {
                Button("別のフォルダを選ぶ") { library.chooseFolder() }
            }
        } else if library.loaded && library.photos.isEmpty {
            MessageView(
                symbol: "photo.on.rectangle.angled",
                title: "スクリーンショットがありません",
                text: "\(library.folder.path)\nにはまだ画像がありません。⌘⇧4 でスクリーンショットを撮ると、ここにすぐ表示されます。"
            ) {
                Button("別のフォルダを選ぶ") { library.chooseFolder() }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(makeSections(library.photos)) { section in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 3)], spacing: 3) {
                                ForEach(section.photos) { photo in
                                    ThumbnailView(photo: photo, maxPixel: thumbSize > 200 ? 720 : 400)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selected = photo.url }
                                        .contextMenu { PhotoMenu(photo: photo) }
                                        .help(photo.name)
                                }
                            }
                            .padding(.horizontal, 3)
                        } header: {
                            Text(section.title)
                                .font(.title3.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

struct PhotoMenu: View {
    @EnvironmentObject private var library: Library
    let photo: Photo

    var body: some View {
        Button("コピー") { PhotoActions.copy(photo) }
        Button("プレビューで開く") { PhotoActions.open(photo) }
        Button("Finderで表示") { PhotoActions.revealInFinder(photo) }
        Divider()
        Button("ゴミ箱に入れる") { library.trash(photo) }
    }
}

struct MessageView<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            actions()
        }
        .frame(maxWidth: 460)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ThumbnailView: View {
    let photo: Photo
    let maxPixel: Int
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: "\(photo.id)|\(maxPixel)") {
                image = await ImageLoader.thumbnail(for: photo, maxPixel: maxPixel)
            }
    }
}

// MARK: - Viewer

struct ViewerView: View {
    @EnvironmentObject private var library: Library
    @Binding var selected: URL?

    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var swipeAccum: CGFloat = 0
    @State private var swipeDone = false
    @State private var monitor: Any?

    private var index: Int? { library.photos.firstIndex { $0.url == selected } }
    private var photo: Photo? { index.map { library.photos[$0] } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(zoom)
                            .offset(offset)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleZoom() }
                .gesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
            }
            .padding(.vertical, 56)

            HStack {
                navButton(-1, "chevron.left")
                Spacer()
                navButton(1, "chevron.right")
            }
            .padding(.horizontal, 12)
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .foregroundStyle(.white)
        .task(id: selected) {
            resetZoom(animated: false)
            guard let url = selected else { return }
            if index == nil { selected = nil; return }
            image = await ImageLoader.full(url)
        }
        .onChange(of: library.photos) { _ in
            if index == nil { selected = nil }
        }
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
    }

    private var topBar: some View {
        HStack {
            Button { selected = nil } label: {
                Label("閉じる", systemImage: "xmark")
            }
            .help("一覧に戻る (esc)")
            Spacer()
            if let photo {
                VStack(spacing: 2) {
                    Text(photo.name).font(.callout).lineLimit(1)
                    Text(photo.date.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Text(index.map { "\($0 + 1) / \(library.photos.count)" } ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(minWidth: 70, alignment: .trailing)
        }
        .buttonStyle(ViewerButtonStyle())
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button { photo.map(PhotoActions.copy) } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
            .help("クリップボードにコピー (⌘C)")
            Button { toggleZoom() } label: {
                Label(zoom > 1 ? "全体" : "拡大", systemImage: zoom > 1 ? "minus.magnifyingglass" : "plus.magnifyingglass")
            }
            .help("拡大／全体表示 (スペース)")
            Button { photo.map(PhotoActions.open) } label: {
                Label("プレビュー", systemImage: "pencil.tip.crop.circle")
            }
            .help("プレビューで開いて編集")
            Button { photo.map(PhotoActions.revealInFinder) } label: {
                Label("Finder", systemImage: "folder")
            }
            .help("Finderで表示")
            Button { trashCurrent() } label: {
                Label("削除", systemImage: "trash")
            }
            .help("ゴミ箱に入れる (⌘⌫)")
        }
        .buttonStyle(ViewerButtonStyle())
        .frame(height: 56)
    }

    private func navButton(_ delta: Int, _ symbol: String) -> some View {
        let enabled = index.map { $0 + delta >= 0 && $0 + delta < library.photos.count } ?? false
        return Button { go(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 44, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.75 : 0)
        .disabled(!enabled)
    }

    // MARK: Navigation & zoom

    private func go(_ delta: Int) {
        guard let i = index else { return }
        let n = i + delta
        guard n >= 0, n < library.photos.count else {
            withAnimation(.spring(response: 0.25)) { offset = .zero }
            return
        }
        selected = library.photos[n].url
    }

    private func trashCurrent() {
        guard let i = index else { return }
        let photo = library.photos[i]
        let photos = library.photos
        let next = i + 1 < photos.count ? photos[i + 1].url : (i > 0 ? photos[i - 1].url : nil)
        library.trash(photo)
        selected = next
    }

    private func resetZoom(animated: Bool) {
        let apply = {
            zoom = 1; baseZoom = 1
            offset = .zero; baseOffset = .zero
        }
        if animated { withAnimation(.easeOut(duration: 0.2), apply) } else { apply() }
    }

    private func toggleZoom() {
        if zoom > 1 {
            resetZoom(animated: true)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { zoom = 2.5; baseZoom = 2.5 }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = min(max(baseZoom * value, 1), 8) }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { resetZoom(animated: true) }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                if zoom > 1 {
                    offset = CGSize(width: baseOffset.width + v.translation.width,
                                    height: baseOffset.height + v.translation.height)
                } else {
                    offset = CGSize(width: v.translation.width, height: 0)
                }
            }
            .onEnded { v in
                if zoom > 1 {
                    baseOffset = offset
                } else if v.translation.width < -80 {
                    go(1)
                } else if v.translation.width > 80 {
                    go(-1)
                } else {
                    withAnimation(.spring(response: 0.25)) { offset = .zero }
                }
            }
    }

    // MARK: Keyboard & trackpad

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { event in
            guard selected != nil else { return event }
            if event.type == .keyDown { return handleKey(event) ? nil : event }
            handleScroll(event)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: selected = nil                      // esc
        case 123: go(-1)                             // ←
        case 124: go(1)                              // →
        case 49: toggleZoom()                        // space
        case 51 where cmd: trashCurrent()            // ⌘⌫
        case 8 where cmd: photo.map(PhotoActions.copy) // ⌘C
        default: return false
        }
        return true
    }

    /// 2本指スワイプで前後へ。拡大中は移動。
    private func handleScroll(_ e: NSEvent) {
        if zoom > 1 {
            offset.width += e.scrollingDeltaX
            offset.height += e.scrollingDeltaY
            baseOffset = offset
            return
        }
        if e.phase == .began {
            swipeAccum = 0
            swipeDone = false
        }
        guard e.phase != [], e.momentumPhase == [] else { return }
        swipeAccum += e.scrollingDeltaX
        if !swipeDone, abs(swipeAccum) > 60 {
            go(swipeAccum > 0 ? -1 : 1)
            swipeDone = true
        }
    }
}

struct ViewerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.25 : 0.1), in: Capsule())
            .contentShape(Capsule())
    }
}
