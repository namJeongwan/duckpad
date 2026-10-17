import AppKit
import GhosttyKit
import DuckpadPresentation

extension GhosttyRuntime {
    func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: GhosttySurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
           let pointer = ghostty_surface_userdata(surface) {
            view = Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).takeUnretainedValue()
        } else { view = focusedSurface }
        // Mutations must occur after returning to Ghostty: callbacks may be on a surface's stack.
        func route(_ command: TerminalAction) -> Bool {
            guard let view else { return false }
            DispatchQueue.main.async { [weak view] in view?.onAction?(command) }
            return true
        }
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            if let surface = view?.surface { ghostty_surface_draw(surface) }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            if let title = action.action.set_title.title { view?.toolTip = String(cString: title) }
            return true
        case GHOSTTY_ACTION_PWD:
            if let path = action.action.pwd.pwd { view?.workingDirectory = URL(fileURLWithPath: String(cString: path)) }
            return true
        case GHOSTTY_ACTION_NEW_TAB: return route(.newTab)
        case GHOSTTY_ACTION_NEW_WINDOW: return route(.newWindow)
        case GHOSTTY_ACTION_CLOSE_TAB: return route(.closeTab)
        case GHOSTTY_ACTION_CLOSE_WINDOW: return route(.closeWindow)
        case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS: return route(.closeAllWindows)
        case GHOSTTY_ACTION_GOTO_TAB: return route(.selectTab(Int(action.action.goto_tab.rawValue)))
        case GHOSTTY_ACTION_NEW_SPLIT:
            return route(.split(action.action.new_split == GHOSTTY_SPLIT_DIRECTION_DOWN ? .down : .right))
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let direction: TerminalDirection
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: direction = .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: direction = .next
            case GHOSTTY_GOTO_SPLIT_UP: direction = .up
            case GHOSTTY_GOTO_SPLIT_DOWN: direction = .down
            case GHOSTTY_GOTO_SPLIT_LEFT: direction = .left
            default: direction = .right
            }
            return route(.focusSplit(direction))
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let value = action.action.resize_split
            let direction: TerminalDirection
            switch value.direction {
            case GHOSTTY_RESIZE_SPLIT_UP: direction = .up
            case GHOSTTY_RESIZE_SPLIT_DOWN: direction = .down
            case GHOSTTY_RESIZE_SPLIT_LEFT: direction = .left
            default: direction = .right
            }
            return route(.resizeSplit(direction, Int(value.amount)))
        case GHOSTTY_ACTION_EQUALIZE_SPLITS: return route(.equalizeSplits)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM: return route(.toggleSplitZoom)
        case GHOSTTY_ACTION_UNDO: return route(.undo)
        case GHOSTTY_ACTION_REDO: return route(.redo)
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE: return route(.commandPalette)
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            DispatchQueue.main.async { [weak view] in view?.window?.toggleFullScreen(nil) }
            return true
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true
        case GHOSTTY_ACTION_OPEN_CONFIG:
            DispatchQueue.main.async { [weak self] in self?.openConfiguration() }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            DispatchQueue.main.async { [weak self] in self?.reloadConfiguration() }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let data = action.action.open_url
            if let pointer = data.url, let url = URL(string: String(decoding: UnsafeBufferPointer(start: pointer, count: Int(data.len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)) {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            DispatchQueue.main.async { [weak view] in view?.showSearch(needle: needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            DispatchQueue.main.async { [weak view] in view?.hideSearch() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            view?.searchTotal = Int(action.action.search_total.total); return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            view?.searchSelected = Int(action.action.search_selected.selected); return true
        case GHOSTTY_ACTION_INSPECTOR:
            DispatchQueue.main.async { [weak view] in view?.toggleInspector() }
            return true
        default: return false
        }
    }
}
