import AppKit

public final class AboutSettingsViewController: NSViewController {
    private static let repoURL = URL(string: "https://github.com/hadesh/ClaudeStatusBar")!

    public override func loadView() {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage ?? OctopusIcon.image(
            color: SettingsStore.defaultWorkingColor,
            size: NSSize(width: 96, height: 96),
            isTemplate: false
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        icon.imageScaling = .scaleProportionallyUpOrDown

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let appName = info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "ClaudeStatusBar"

        let title = NSTextField(labelWithString: "\(appName)  \(version)")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)

        let copyright = NSTextField(labelWithString: "© 2026 Hades · MIT License")
        copyright.textColor = .secondaryLabelColor
        copyright.font = NSFont.systemFont(ofSize: 11)

        let github = NSButton(title: "GitHub", target: self, action: #selector(openRepo(_:)))
        github.bezelStyle = .inline
        github.contentTintColor = .controlAccentColor

        let stack = NSStackView(views: [icon, title, copyright, github])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 24, bottom: 32, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        preferredContentSize = NSSize(width: 360, height: 260)
    }

    @objc private func openRepo(_ sender: NSButton) {
        NSWorkspace.shared.open(Self.repoURL)
    }
}
