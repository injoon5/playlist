import AppKit
import SwiftUI

/// Per-track status during a run.
struct RunTableView: NSViewRepresentable {
    var rows: [RunModel.Row]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id, title, width) in [("index", "#", 30.0), ("title", "Title", 220.0), ("artist", "Artist", 150.0), ("status", "Status", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "index" ? 30 : 70
            if id == "index" { column.maxWidth = 30 }
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        context.coordinator.rows = rows

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = coordinator.table, coordinator.rows != rows else { return }
        let old = coordinator.rows
        coordinator.rows = rows
        if old.count != rows.count {
            table.reloadData()
            return
        }
        let changed = IndexSet(rows.indices.filter { rows[$0] != old[$0] })
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        if let active = rows.firstIndex(where: { $0.status == "rendering" || $0.status == "downloading" }) {
            table.scrollRowToVisible(active)
        }
    }

    /// Human wording + symbol + colour for a (phase, status) pair.
    static func describe(_ row: RunModel.Row) -> (String, String, NSColor) {
        switch (row.phase, row.status) {
        case ("download", "pending"): return ("Waiting", "circle.dotted", .tertiaryLabelColor)
        case ("download", "downloading"): return ("Downloading", "arrow.down.circle", .controlAccentColor)
        case ("download", "ok"): return ("Downloaded", "arrow.down.circle.fill", .secondaryLabelColor)
        case ("render", "pending"): return ("Queued", "clock", .secondaryLabelColor)
        case ("render", "rendering"): return ("Rendering", "film", .controlAccentColor)
        case ("render", "ok"): return ("Done", "checkmark.circle.fill", .systemGreen)
        case (_, "skipped"): return ("No audio found", "minus.circle", .systemOrange)
        case (_, "failed"): return ("Failed", "xmark.octagon.fill", .systemRed)
        case (_, "cancelled"): return ("Cancelled", "stop.circle", .secondaryLabelColor)
        default: return (row.status.capitalized, "circle", .secondaryLabelColor)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [RunModel.Row] = []
        weak var table: NSTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
            let item = rows[row]
            let identifier = NSUserInterfaceItemIdentifier("run.\(id)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                var constraints = [
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ]
                if id == "status" {
                    let image = NSImageView()
                    image.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(image)
                    cell.imageView = image
                    constraints += [
                        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        image.widthAnchor.constraint(equalToConstant: 16),
                        field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    ]
                } else {
                    constraints.append(field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
                }
                NSLayoutConstraint.activate(constraints)
                return cell
            }()
            let field = cell.textField!
            field.textColor = .labelColor
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.alignment = .left
            switch id {
            case "index":
                field.stringValue = "\(item.id)"
                field.alignment = .right
                field.textColor = .secondaryLabelColor
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            case "title": field.stringValue = item.title
            case "artist":
                field.stringValue = item.artist
                field.textColor = .secondaryLabelColor
            default:
                let (text, symbol, color) = RunTableView.describe(item)
                field.stringValue = text
                field.textColor = color == .controlAccentColor ? .labelColor : color
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
                cell.imageView?.contentTintColor = color
            }
            return cell
        }
    }
}
