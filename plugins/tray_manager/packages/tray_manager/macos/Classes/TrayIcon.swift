import SwiftUI
//
//  TrayIcon.swift
//  tray_manager
//
//  Created by Lijy91 on 2022/5/15.
//

// Self-drawn text view: unlike NSTextField, drawing here does not go through
// the AppKit appearance machinery, so redrawing a status-item replicant does
// not re-dirty the view and re-schedule another replicant update. This breaks
// the self-sustaining NSStatusItem redraw loop seen on newer macOS with
// multiple displays ("Displays have separate Spaces").
private final class SpeedTextView: NSView {
    var attributedText: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let text = attributedText else { return }
        let textSize = text.boundingRect(
            with: NSSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size
        let y = (bounds.height - textSize.height) / 2
        text.draw(
            with: NSRect(x: 0, y: y, width: bounds.width, height: textSize.height),
            options: [.usesLineFragmentOrigin]
        )
    }
}

public class TrayIcon: NSView {
    public var onTrayIconMouseDown:(() -> Void)?
    public var onTrayIconMouseUp:(() -> Void)?
    public var onTrayIconRightMouseDown:(() -> Void)?
    public var onTrayIconRightMouseUp:(() -> Void)?
    
    var statusItem: NSStatusItem?
    
    var textAttributes: [NSAttributedString.Key : Any]?
    
    private let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.isHidden = true
        iv.setContentHuggingPriority(.required, for: .horizontal)
        return iv
    }()
    
    private let textView: SpeedTextView = {
        let view = SpeedTextView()
        view.isHidden = true
        return view
    }()
    
    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .equalSpacing
        return stack
    }()
    
    
    public init() {
        super.init(frame: NSRect.zero)
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.maximumLineHeight = 9
        paragraphStyle.minimumLineHeight = 9
        paragraphStyle.alignment = .right
        paragraphStyle.lineBreakMode = .byClipping
        
        textAttributes = [
            .paragraphStyle: paragraphStyle,
            .font: NSFont.systemFont(ofSize: 8.75),
            .foregroundColor: NSColor.labelColor
        ]
        
        if let button = statusItem?.button {
            button.addSubview(self)
            self.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                self.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                self.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                self.topAnchor.constraint(equalTo: button.topAnchor),
                self.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                self.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness),
            ])
            setupView()
        }
    }
    
    private func setupView() {
        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor,constant: 8),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor,constant: -8),
            stackView.topAnchor.constraint(equalTo: topAnchor,constant:2),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor,constant:-2),
        ])
        
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.widthAnchor.constraint(equalToConstant: 42),
            textView.trailingAnchor.constraint(equalTo:stackView.trailingAnchor),
        ])
    }
    
    
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect);
        setupView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func setImage(_ image: NSImage, _ imagePosition: String) {
        imageView.image = image
        let wasHidden = imageView.isHidden
        imageView.isHidden = false
        // Only re-layout when visibility changes; sizeToFit on every update
        // causes geometry churn that keeps the menu bar redrawing.
        if wasHidden, let button = statusItem?.button {
            button.sizeToFit()
        }
    }
    
    public func setImagePosition(_ imagePosition: String) {
        self.frame = statusItem!.button!.frame
    }
    
    public func removeImage() {
        statusItem?.button?.image = nil
        self.frame = statusItem!.button!.frame
    }
    
    public func setTitle(_ title: String) {
        textView.attributedText = NSAttributedString(string: title, attributes: textAttributes)
        let shouldHide = title.isEmpty
        let hiddenChanged = textView.isHidden != shouldHide
        textView.isHidden = shouldHide
        // The text slot has a fixed width, so only hidden-state changes
        // affect geometry and require a re-layout.
        if hiddenChanged, let button = statusItem?.button {
            button.sizeToFit()
        }
    }
    
    public func setToolTip(_ toolTip: String) {
        if let button = statusItem?.button {
            button.toolTip  = toolTip
        }
    }
    
    public override func mouseDown(with event: NSEvent) {
        statusItem?.button?.highlight(true)
        self.onTrayIconMouseDown!()
    }
    
    public override func mouseUp(with event: NSEvent) {
        statusItem?.button?.highlight(false)
        self.onTrayIconMouseUp!()
    }
    
    public override func rightMouseDown(with event: NSEvent) {
        self.onTrayIconRightMouseDown!()
    }
    
    public override func rightMouseUp(with event: NSEvent) {
        self.onTrayIconRightMouseUp!()
    }
}
