import AppKit

/// Mouse-only observation. It never consumes an event or activates either window.
@MainActor
final class RecordPanelHoverController {
    typealias Frames = (capsule: NSRect, page: NSRect?)
    private let frames: () -> Frames?
    private let canCollapse: () -> Bool
    private let expand: () -> Void
    private let collapse: () -> Void
    private let pointerLocation: () -> NSPoint
    private let wait: (Duration) async throws -> Void
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pointer = NSPoint.zero
    private var pressedButtons: Set<Int> = []
    private var isDragging = false
    private var waitsForExit = false

    init(frames: @escaping () -> Frames?, canCollapse: @escaping () -> Bool,
         expand: @escaping () -> Void, collapse: @escaping () -> Void,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.frames = frames
        self.canCollapse = canCollapse
        self.expand = expand
        self.collapse = collapse
        self.pointerLocation = pointerLocation
        self.wait = wait
    }

    isolated deinit {
        openTask?.cancel()
        closeTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    func start() {
        guard localMonitor == nil else { return }
        let buttons = NSEvent.pressedMouseButtons
        pressedButtons = Set((0..<Int.bitWidth).filter { buttons & (1 << $0) != 0 })
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        pointerMoved(to: pointerLocation())
    }

    func stop() {
        cancelTimers()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        pressedButtons.removeAll()
        isDragging = false
        waitsForExit = false
    }

    func pointerMoved(to point: NSPoint) {
        pointer = point
        if frames()?.capsule.contains(point) != true { waitsForExit = false }
        refresh()
    }

    func buttonChanged(_ button: Int, isDown: Bool) {
        if isDown { pressedButtons.insert(button) }
        else { pressedButtons.remove(button) }
        refresh()
    }

    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        waitsForExit = frames()?.capsule.contains(pointer) == true
        refresh()
    }

    func suppressUntilExit() {
        waitsForExit = frames()?.capsule.contains(pointer) == true
        cancelTimers()
    }

    func refresh() {
        guard let frames = frames() else { cancelTimers(); return }
        if frames.page == nil {
            closeTask?.cancel()
            closeTask = nil
            guard shouldExpand(frames) else { openTask?.cancel(); openTask = nil; return }
            guard openTask == nil else { return }
            openTask = Task { [weak self, wait] in
                do { try await wait(.milliseconds(300)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.openTask = nil
                guard let frames = self.frames(), self.shouldExpand(frames) else { return }
                self.expand()
            }
        } else {
            openTask?.cancel()
            openTask = nil
            guard shouldCollapse(frames) else { closeTask?.cancel(); closeTask = nil; return }
            guard closeTask == nil else { return }
            closeTask = Task { [weak self, wait] in
                do { try await wait(.milliseconds(700)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.closeTask = nil
                guard let frames = self.frames(), self.shouldCollapse(frames) else { return }
                self.collapse()
            }
        }
    }

    private func shouldExpand(_ frames: Frames) -> Bool {
        var handle = frames.capsule
        handle.size.width -= 40
        return frames.page == nil && handle.contains(pointer) && pressedButtons.isEmpty
            && !isDragging && !waitsForExit
    }

    private func shouldCollapse(_ frames: Frames) -> Bool {
        frames.page != nil && !RecordPanelPlacement.contains(pointer, capsule: frames.capsule, page: frames.page)
            && pressedButtons.isEmpty && !isDragging && canCollapse()
    }

    private func cancelTimers() {
        openTask?.cancel()
        closeTask?.cancel()
        openTask = nil
        closeTask = nil
    }

    private func handle(_ event: NSEvent) {
        pointer = pointerLocation()
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttonChanged(event.buttonNumber, isDown: true)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttonChanged(event.buttonNumber, isDown: false)
        default:
            if NSEvent.pressedMouseButtons == 0 { pressedButtons.removeAll() }
            pointerMoved(to: pointer)
        }
    }
}
