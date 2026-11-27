import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let playlistTrackRow = NSPasteboard.PasteboardType("dev.playlist-gen.track-row")
}

/// The playlist: an NSTableView with an include checkbox per song, editable
/// title / artist / album, Space to toggle the selected rows, and
/// drag-to-reorder (video order = list order).
struct TrackTableView: NSViewRepresentable {
    @Binding var rows: [TrackRow]
    @Binding var focusedRow: TrackRow.ID?

    static let editableColumns: Set<String> = ["title", "artist", "album"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 28
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat, max: CGFloat = 10_000, tip: String? = nil) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = min
            column.maxWidth = max
            column.headerToolTip = tip
            if id == "include" || id == "index" || id == "time" { column.resizingMask = [] }
            table.addTableColumn(column)
        }
        column("include", "", width: 20, min: 20, max: 20, tip: "Include in the video")
        column("index", "#", width: 28, min: 28, max: 28)
        column("title", "Title", width: 260, min: 120, tip: "Double-click to edit")
        column("artist", "Artist", width: 170, min: 80, tip: "Double-click to edit")
        column("album", "Album", width: 170, min: 80, tip: "Double-click to edit")
        column("time", "Time", width: 46, min: 46, max: 46)
        table.tableColumns.last?.headerCell.alignment = .right
        table.tableColumns[1].headerCell.alignment = .right
        // Remember column widths across launches.
        table.autosaveName = "TrackTable"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        coordinator.rows = rows
        table.dataSource = coordinator
        table.delegate = coordinator
        table.onToggle = { [weak coordinator] in coordinator?.toggleTargetRows() }
        table.onEdit = { [weak coordinator] in coordinator?.editSelected() }
        table.onCopy = { [weak coordinator] in coordinator?.copySelected() }
        table.onDelete = { [weak coordinator] in coordinator?.excludeSelected() }
        table.registerForDraggedTypes([.playlistTrackRow])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table

        // Coming back from the run screen (or relaunching): keep the song
        // the preview shows selected and in view.
        if let row = rows.firstIndex(where: { $0.id == focusedRow }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.undoManager = context.environment.undoManager
        guard coordinator.rows != rows, let table = coordinator.table else { return }
        let sameRows = coordinator.rows.map(\.id) == rows.map(\.id)
        coordinator.rows = rows
        // Don't yank the field editor away from an in-progress edit.
        if table.currentEditor() != nil, sameRows { return }
        if sameRows {
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<rows.count),
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        } else {
            table.reloadData()
            if let first = rows.firstIndex(where: { $0.id == focusedRow }) {
                table.selectRowIndexes([first], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: TrackTableView
        var rows: [TrackRow] = []
        weak var table: NSTableView?
        weak var undoManager: UndoManager?

        /// Apply a change to the song list, undoable with ⌘Z.
        private func commit(_ updated: [TrackRow], _ actionName: String) {
            let previous = parent.rows
            guard previous != updated else { return }
            parent.rows = updated
            undoManager?.registerUndo(withTarget: self) { coordinator in
                MainActor.assumeIsolated { coordinator.commit(previous, actionName) }
            }
            undoManager?.setActionName(actionName)
        }

        func copySelected() {
            guard let table else { return }
            let lines = table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].track : nil }
                .map { "\($0.title) — \($0.artist)" }
            guard !lines.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }

        init(_ parent: TrackTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < rows.count else { return nil }
            let id = column.identifier.rawValue
            let item = rows[row]
            if id == "include" {
                let button = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSButton ?? {
                    let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
                    b.identifier = column.identifier
                    b.toolTip = "Include in the video (⌘-click to change every song)"
                    return b
                }()
                button.state = item.included ? .on : .off
                button.setAccessibilityLabel("Include “\(item.track.title)” in video")
                return button
            }
            let cell = textCell(tableView, id: id)
            let field = cell.textField!
            let editable = TrackTableView.editableColumns.contains(id)
            field.isEditable = editable
            field.alignment = (id == "index" || id == "time") ? .right : .left
            let size = NSFont.systemFontSize
            switch id {
            case "index":
                field.stringValue = "\(row + 1)"
                field.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            case "time":
                field.stringValue = item.track.durationMs.map { formatDuration(Double($0) / 1000) } ?? "—"
                field.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            case "title":
                field.stringValue = item.track.title
                field.font = .systemFont(ofSize: size, weight: .medium)
            case "artist":
                field.stringValue = item.track.artist
                field.font = .systemFont(ofSize: size)
            case "album":
                field.stringValue = item.track.album
                field.font = .systemFont(ofSize: size)
            default:
                break
            }
            let secondary = !editable || id != "title"
            field.textColor = !item.included ? .tertiaryLabelColor : (secondary ? .secondaryLabelColor : .labelColor)
            field.toolTip = editable ? editTooltip(item, id: id) : nil
            return cell
        }

        private func editTooltip(_ item: TrackRow, id: String) -> String {
            let original: String
            let current: String
            switch id {
            case "title": (original, current) = (item.original.title, item.track.title)
            case "artist": (original, current) = (item.original.artist, item.track.artist)
            default: (original, current) = (item.original.album, item.track.album)
            }
            return original == current ? current : "\(current)\nEdited (Apple Music: \(original))"
        }

        private func textCell(_ tableView: NSTableView, id: String) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("cell.\(id)")
            if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                return cell
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.identifier = NSUserInterfaceItemIdentifier(id)
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.delegate = self
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, let first = table.selectedRowIndexes.first, first < rows.count else { return }
            if parent.focusedRow != rows[first].id { parent.focusedRow = rows[first].id }
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let table,
                  let id = field.identifier?.rawValue else { return }
            let row = table.row(for: field)
            guard row >= 0, row < parent.rows.count else { return }
            var updated = parent.rows
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let original = updated[row].original
            // Clearing a field restores Apple Music's value.
            switch id {
            case "title": updated[row].track.title = value.isEmpty ? original.title : value
            case "artist": updated[row].track.artist = value.isEmpty ? original.artist : value
            case "album": updated[row].track.album = value.isEmpty ? original.album : value
            default: return
            }
            if updated[row] != parent.rows[row] {
                commit(updated, "Rename")
            } else {
                // Unchanged, but put back the canonical value (e.g. after clearing).
                table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        /// Escape while renaming puts the old text back, like Finder.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let table else { return false }
            let row = table.row(for: control)
            control.abortEditing()
            if row >= 0 {
                table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            table.window?.makeFirstResponder(table)
            return true
        }

        func editSelected() {
            guard let table, let row = table.selectedRowIndexes.first else { return }
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("title"))
            table.editColumn(column, row: row, with: nil, select: true)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0 else { return }
            let id = table.tableColumns[table.clickedColumn].identifier.rawValue
            if TrackTableView.editableColumns.contains(id) {
                table.editColumn(table.clickedColumn, row: table.clickedRow, with: nil, select: true)
            } else {
                setIncluded(!rows[table.clickedRow].included, rows: [table.clickedRow])
            }
        }

        private func revert(_ indexes: IndexSet) {
            var updated = parent.rows
            for i in indexes where i < updated.count {
                var t = updated[i].original
                t.index = updated[i].track.index
                updated[i].track = t
            }
            commit(updated, "Revert to Apple Music Info")
        }

        // MARK: Including / excluding

        /// Rows an action applies to: the clicked row, or the selection when
        /// the clicked row is part of it.
        private func targetRows(clicked: Int? = nil) -> IndexSet {
            guard let table else { return [] }
            let clicked = clicked ?? table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) { return [clicked] }
            return table.selectedRowIndexes
        }

        private func setIncluded(_ included: Bool, rows indexes: IndexSet) {
            var updated = parent.rows
            for i in indexes where i < updated.count { updated[i].included = included }
            commit(updated, included ? "Include" : "Exclude")
        }

        @objc func checkboxClicked(_ sender: NSButton) {
            guard let table else { return }
            let row = table.row(for: sender)
            guard row >= 0 else { return }
            // ⌘-click checks or unchecks every song, as in Music / iTunes.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                setIncluded(sender.state == .on, rows: IndexSet(integersIn: 0..<rows.count))
                return
            }
            setIncluded(sender.state == .on, rows: targetRows(clicked: row))
        }

        func excludeSelected() {
            guard let table, !table.selectedRowIndexes.isEmpty else { return }
            setIncluded(false, rows: table.selectedRowIndexes)
        }

        func toggleTargetRows() {
            let indexes = targetRows(clicked: -1)
            guard !indexes.isEmpty else { return }
            // Mixed selection → include all; otherwise flip.
            let allIncluded = indexes.allSatisfy { $0 < rows.count && rows[$0].included }
            setIncluded(!allIncluded, rows: indexes)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = targetRows()
            guard !targets.isEmpty else { return }
            let plural = targets.count > 1
            func add(_ title: String, _ action: Selector) {
                menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
            }
            if targets.contains(where: { $0 < rows.count && !rows[$0].included }) {
                add(plural ? "Include Songs" : "Include Song", #selector(includeClicked))
            }
            if targets.contains(where: { $0 < rows.count && rows[$0].included }) {
                add(plural ? "Exclude Songs" : "Exclude Song", #selector(excludeClicked))
            }
            menu.addItem(.separator())
            if !plural { add("Edit Title", #selector(editClicked)) }
            if targets.contains(where: { $0 < rows.count && rows[$0].isEdited }) {
                add("Revert to Apple Music Info", #selector(revertClicked))
            }
            menu.addItem(.separator())
            add("Move to Top", #selector(moveToTop))
            add("Move to Bottom", #selector(moveToBottom))
            menu.addItem(.separator())
            add("Copy", #selector(copyClicked))
        }

        @objc private func includeClicked() { setIncluded(true, rows: targetRows()) }
        @objc private func excludeClicked() { setIncluded(false, rows: targetRows()) }
        @objc private func revertClicked() { revert(targetRows()) }
        @objc private func moveToTop() { move(targetRows(), to: 0) }
        @objc private func moveToBottom() { move(targetRows(), to: rows.count) }
        @objc private func copyClicked() {
            guard let table else { return }
            let targets = targetRows()
            if targets != table.selectedRowIndexes {
                table.selectRowIndexes(targets, byExtendingSelection: false)
            }
            copySelected()
        }
        @objc private func editClicked() {
            guard let table, let row = targetRows().first else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            editSelected()
        }

        // MARK: Reordering

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .playlistTrackRow)
            return item
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) === tableView else { return [] }
            if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            var indexes = IndexSet()
            info.enumerateDraggingItems(
                options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]
            ) { item, _, _ in
                if let string = (item.item as? NSPasteboardItem)?.string(forType: .playlistTrackRow),
                   let index = Int(string) {
                    indexes.insert(index)
                }
            }
            guard !indexes.isEmpty else { return false }
            move(indexes, to: row)
            return true
        }

        private func move(_ indexes: IndexSet, to destination: Int) {
            guard let table, !indexes.isEmpty else { return }
            let moved = Set(indexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            var updated = parent.rows
            updated.move(fromOffsets: indexes, toOffset: destination)
            rows = updated
            commit(updated, "Move")
            table.reloadData()
            table.selectRowIndexes(
                IndexSet(updated.indices.filter { moved.contains(updated[$0].id) }), byExtendingSelection: false
            )
        }
    }
}

/// Space toggles the selected rows' checkboxes; Return edits the title;
/// Delete unchecks (excludes) the selected songs.
final class TrackNSTableView: NSTableView {
    var onToggle: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    /// Columns restored from autosave (or saved while the inspector was
    /// hidden) can add up to more than the visible width; uniform resizing
    /// only scales them relative to each other, so fit them back in.
    private var fitting = false
    override func layout() {
        super.layout()
        guard !fitting, let clip = enclosingScrollView?.contentView else { return }
        let total = tableColumns.reduce(0) { $0 + $1.width + intercellSpacing.width }
        if total > clip.bounds.width + 1 {
            fitting = true
            sizeToFit()
            fitting = false
        }
    }

    /// Take keyboard focus when the list appears (after loading, relaunching
    /// or returning from the run screen) so arrow keys and Space just work.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            if window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(self)
            }
        }
    }

    /// Edit › Copy: "Title — Artist" per selected song.
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty {
            switch event.charactersIgnoringModifiers {
            case " ":
                onToggle?()
                return
            case "\r":
                onEdit?()
                return
            case "\u{7F}", String(UnicodeScalar(NSDeleteFunctionKey)!):
                onDelete?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
