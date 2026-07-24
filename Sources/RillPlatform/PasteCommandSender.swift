import ApplicationServices

public enum PasteCommandSender {
    static let eventTapName = "cghidEventTap"
    static let eventSourceStateName = "privateState"
    private static let commandKeyCode: CGKeyCode = 0x37
    private static let commandVKeyCode: CGKeyCode = 0x09
    private static let pasteShortcutEventDelay: Duration = .milliseconds(10)

    public static func send() -> Bool {
        guard let events = makeCommandVEvents() else { return false }
        post(events)
        return true
    }

    public static func sendWithEventSpacing() async -> Bool {
        guard let events = makeCommandVEvents() else { return false }
        await postWithEventSpacing(events)
        return true
    }

    static func makeEventSource() -> CGEventSource? {
        let eventSource = CGEventSource(stateID: .privateState)
        eventSource?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return eventSource
    }

    private static func makeCommandVEvents() -> [CGEvent]? {
        guard
            let eventSource = makeEventSource(),
            let commandDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: commandKeyCode,
                keyDown: true
            ),
            let keyDown = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: commandVKeyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: commandVKeyCode,
                keyDown: false
            ),
            let commandUp = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: commandKeyCode,
                keyDown: false
            )
        else {
            return nil
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return [commandDown, keyDown, keyUp, commandUp]
    }

    private static func post(_ events: [CGEvent]) {
        events.forEach { $0.post(tap: .cghidEventTap) }
    }

    private static func postWithEventSpacing(_ events: [CGEvent]) async {
        for (index, event) in events.enumerated() {
            event.post(tap: .cghidEventTap)
            if index < events.count - 1 {
                try? await Task.sleep(for: pasteShortcutEventDelay)
            }
        }
    }
}
