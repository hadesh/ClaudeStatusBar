import AppKit
import Combine

public final class AppearanceSettingsViewController: NSViewController {
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()

    private let workingWell = NSColorWell()
    private let attentionWell = NSColorWell()
    private let idlePreview = NSImageView()
    private let workingPreview = NSImageView()
    private let attentionPreview = NSImageView()

    public init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let workingRow = makeColorRow(label: "工作色:", well: workingWell)
        let attentionRow = makeColorRow(label: "等待色:", well: attentionWell)

        let previewLabel = NSTextField(labelWithString: "实时预览(空闲 / 工作 / 等待):")
        previewLabel.textColor = .secondaryLabelColor
        for v in [idlePreview, workingPreview, attentionPreview] {
            v.imageScaling = .scaleNone
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 32).isActive = true
            v.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        let previewRow = NSStackView(views: [idlePreview, workingPreview, attentionPreview])
        previewRow.orientation = .horizontal
        previewRow.spacing = 12

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(reset(_:)))
        resetButton.bezelStyle = .rounded

        stack.addArrangedSubview(workingRow)
        stack.addArrangedSubview(attentionRow)
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(previewRow)
        stack.addArrangedSubview(resetButton)

        workingWell.target = self
        workingWell.action = #selector(workingChanged(_:))
        attentionWell.target = self
        attentionWell.action = #selector(attentionChanged(_:))

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 380, height: 240)

        workingWell.color = settings.workingColor
        attentionWell.color = settings.attentionColor
        renderPreview()
        observe()
    }

    private func makeColorRow(label: String, well: NSColorWell) -> NSStackView {
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 56).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let title = NSTextField(labelWithString: label)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [title, well])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func observe() {
        settings.$workingColor
            .sink { [weak self] _ in self?.renderPreview() }
            .store(in: &cancellables)
        settings.$attentionColor
            .sink { [weak self] _ in self?.renderPreview() }
            .store(in: &cancellables)
    }

    private func renderPreview() {
        let size = NSSize(width: 32, height: 32)
        idlePreview.image = OctopusIcon.image(color: .labelColor, size: size, isTemplate: false)
        workingPreview.image = OctopusIcon.image(color: settings.workingColor, size: size, isTemplate: false)
        attentionPreview.image = OctopusIcon.image(color: settings.attentionColor, size: size, isTemplate: false)
        workingWell.color = settings.workingColor
        attentionWell.color = settings.attentionColor
    }

    @objc private func workingChanged(_ sender: NSColorWell) {
        settings.workingColor = sender.color
    }

    @objc private func attentionChanged(_ sender: NSColorWell) {
        settings.attentionColor = sender.color
    }

    @objc private func reset(_ sender: NSButton) {
        settings.resetColors()
    }
}
