import ImpDesign
import SwiftUI
import UIKit

// A picture from the chat, full screen. It flies out of its place in the chat and back into it, the way photos
// do, and every move is this file's own: the system's swipe-to-close (of its zoom transition) works anywhere on
// the screen, and where it may start can't be relied on, so it isn't used. Closing is a pull on the picture
// itself: it starts only on the picture as it shows (not the black beside it, nor the buttons), only while it
// isn't zoomed in, and the very picture that is pulled flies back into its place in the chat.

/// The picture in the chat: a UIKit view, so the full-screen picture knows where it comes from and goes back to.
/// A tap opens it full screen, or opens its link (`opens`) when the picture links somewhere.
struct ChatPicture: UIViewRepresentable {
    let image: UIImage
    /// What VoiceOver says for it.
    var label: String
    /// The file (or web address) Share hands on in the full-screen view.
    var share: URL?
    /// A picture that links somewhere opens that instead.
    var opens: (() -> Void)?

    func makeUIView(context: Context) -> ChatPictureView {
        let view = ChatPictureView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.layer.cornerRadius = Radius.medium
        view.layer.cornerCurve = .continuous
        view.isUserInteractionEnabled = true
        view.isAccessibilityElement = true
        view.accessibilityTraits = [.image, .button]
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(ChatPictureView.tapped)))
        return view
    }

    func updateUIView(_ view: ChatPictureView, context: Context) {
        if view.image !== image { view.image = image }
        view.accessibilityLabel = label
        view.share = share
        view.opens = opens
    }

    /// As big as the box it is given (which has the picture's shape), not the picture's own pixel size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ChatPictureView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class ChatPictureView: UIImageView {
    var share: URL?
    var opens: (() -> Void)?

    @objc func tapped() {
        if let opens { return opens() }
        guard let image else { return }
        PictureViewer.present(image, label: accessibilityLabel ?? "", share: share, from: self)
    }

    override func accessibilityActivate() -> Bool {
        tapped()
        return true
    }
}

/// The full-screen picture. Pinch or double-tap to look closer. Close by pulling the picture down, with the
/// close button, or with VoiceOver's escape gesture.
final class PictureViewer: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let image: UIImage
    private let label: String
    private let share: URL?
    /// Its place in the chat, hidden while it is open here (so there is only ever one of it).
    private weak var source: UIView?
    private let scroll: PictureScroll
    private let backdrop = UIView()
    private let bar = UIStackView()
    /// The picture while it flies (in, out, or pulled by a finger): the scroll view hides meanwhile.
    private var flying: UIImageView?
    private var opened = false

    private static let pullDistance: CGFloat = 320
    private static let closeDistance: CGFloat = 110
    private static let closeSpeed: CGFloat = 900
    private static let doubleTapScale: CGFloat = 2.5

    /// Opens the picture full screen, from the screen that shows `source`.
    static func present(_ image: UIImage, label: String, share: URL?, from source: UIView) {
        guard var top = source.window?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let viewer = PictureViewer(image: image, label: label, share: share, source: source)
        // Over the chat, which stays drawn underneath: it shows through as the picture is pulled away.
        viewer.modalPresentationStyle = .overFullScreen
        viewer.modalPresentationCapturesStatusBarAppearance = true
        top.present(viewer, animated: false)
    }

    private init(image: UIImage, label: String, share: URL?, source: UIView) {
        self.image = image
        self.label = label
        self.share = share
        self.source = source
        scroll = PictureScroll(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)

        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.accessibilityLabel = label
        scroll.isHidden = true
        view.addSubview(scroll)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        // On the picture's own view: a drag on the black beside it, or on the buttons, never closes it.
        let pull = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pull.delegate = self
        scroll.picture.isUserInteractionEnabled = true
        scroll.picture.addGestureRecognizer(pull)

        bar.axis = .horizontal
        bar.alignment = .center
        bar.distribution = .equalSpacing
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.alpha = 0
        bar.addArrangedSubview(button("xmark", label: String(localized: "common.close"), action: #selector(closeTapped)))
        bar.addArrangedSubview(share == nil ? UIView() : button("square.and.arrow.up", label: String(localized: "Share…"), action: #selector(shareTapped)))
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.page),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.page),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.small),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !opened else { return }
        opened = true
        flyIn()
    }

    /// However it goes, its place in the chat shows its picture again.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        source?.alpha = 1
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    /// A light glyph on a dark disc (the paper and scrim tokens), legible on any picture.
    private func button(_ symbol: String, label: String, action: Selector) -> UIButton {
        var look = UIButton.Configuration.filled()
        look.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        look.baseForegroundColor = UIColor(Tone.paper)
        look.baseBackgroundColor = UIColor(Tone.scrim)
        look.cornerStyle = .capsule
        let button = UIButton(configuration: look)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: Sizing.hit),
                                     button.heightAnchor.constraint(equalToConstant: Sizing.hit)])
        return button
    }

    // MARK: Where it is

    /// The picture's place in the chat, on this screen. Nil when it scrolled away or is gone.
    private var sourceFrame: CGRect? {
        guard let source, source.window != nil else { return nil }
        let frame = source.convert(source.bounds, to: view)
        return view.bounds.intersects(frame) ? frame : nil
    }

    /// Where the picture shows full screen.
    private var shownFrame: CGRect {
        view.layoutIfNeeded()
        return scroll.picture.convert(scroll.shownRect, to: view)
    }

    /// A copy of the picture to fly, at `frame`, with the scroll view hidden behind it.
    private func takeOff(at frame: CGRect, corner: CGFloat) -> UIImageView {
        if let flying { return flying }
        let copy = UIImageView(image: image)
        copy.contentMode = .scaleAspectFill
        copy.clipsToBounds = true
        copy.layer.cornerCurve = .continuous
        copy.layer.cornerRadius = corner
        copy.frame = frame
        view.insertSubview(copy, aboveSubview: scroll)
        scroll.isHidden = true
        flying = copy
        return copy
    }

    private func land() {
        flying?.removeFromSuperview()
        flying = nil
        scroll.isHidden = false
    }

    // MARK: Moves

    private func flyIn() {
        let target = shownFrame
        let copy = takeOff(at: sourceFrame ?? target.insetBy(dx: target.width * 0.1, dy: target.height * 0.1), corner: Radius.medium)
        if sourceFrame == nil { copy.alpha = 0 }
        source?.alpha = 0
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
            copy.frame = target
            copy.layer.cornerRadius = 0
            copy.alpha = 1
            self.backdrop.alpha = 1
            self.bar.alpha = 1
        } completion: { _ in
            self.land()
        }
    }

    /// Flies the picture back into its place in the chat (or fades it, if that place is out of sight), then goes.
    private func flyOut(speed: CGFloat = 0) {
        let copy = takeOff(at: shownFrame, corner: 0)
        let target = sourceFrame
        UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: speed) {
            copy.transform = .identity
            if let target {
                copy.frame = target
                copy.layer.cornerRadius = Radius.medium
            } else {
                copy.alpha = 0
            }
            self.backdrop.alpha = 0
            self.bar.alpha = 0
        } completion: { _ in
            self.source?.alpha = 1
            self.dismiss(animated: false)
        }
    }

    private func close() {
        if scroll.zoomScale > scroll.minimumZoomScale { scroll.setZoomScale(scroll.minimumZoomScale, animated: false) }
        flyOut()
    }

    @objc private func closeTapped() { close() }

    @objc private func shareTapped() {
        guard let share else { return }
        let sheet = UIActivityViewController(activityItems: [share], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = bar
        present(sheet, animated: true)
    }

    /// The pull: the picture follows the finger and gets a little smaller as the chat shows through. Let go far
    /// or fast enough and it flies back into the chat, else it settles back.
    @objc private func pulled(_ pan: UIPanGestureRecognizer) {
        let move = pan.translation(in: view)
        let progress = min(max(move.y, 0) / Self.pullDistance, 1)
        switch pan.state {
        case .began:
            _ = takeOff(at: shownFrame, corner: 0)
        case .changed:
            let scale = 1 - progress * 0.25
            flying?.transform = CGAffineTransform(translationX: move.x, y: move.y).scaledBy(x: scale, y: scale)
            backdrop.alpha = 1 - progress
            bar.alpha = 1 - progress
        case .ended where move.y > Self.closeDistance || pan.velocity(in: view).y > Self.closeSpeed:
            flyOut(speed: min(pan.velocity(in: view).y / 1_000, 3))
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.flying?.transform = .identity
                self.backdrop.alpha = 1
                self.bar.alpha = 1
            } completion: { _ in
                self.land()
            }
        default:
            break
        }
    }

    /// A pull starts on the picture as it shows (not the bars beside it), downward, while it isn't zoomed in.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return false }
        let speed = pan.velocity(in: scroll.picture)
        return speed.y > abs(speed.x) && scroll.shownRect.contains(pan.location(in: scroll.picture))
    }

    /// A picture that isn't zoomed in doesn't scroll: the pull doesn't wait for the scroll view.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll.picture }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { scroll.centre() }

    /// Closer where it was tapped, or back to the whole picture.
    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if scroll.zoomScale > scroll.minimumZoomScale {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let point = tap.location(in: scroll.picture)
            let size = CGSize(width: scroll.bounds.width / Self.doubleTapScale, height: scroll.bounds.height / Self.doubleTapScale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                        animated: true)
        }
    }
}

/// The scroll view the picture zooms in: the picture fills it at its own shape, centred when it is smaller.
private final class PictureScroll: UIScrollView {
    let picture: UIImageView

    init(image: UIImage) {
        picture = UIImageView(image: image)
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFit
        addSubview(picture)
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Unzoomed, the picture is exactly the screen. Zoomed, it keeps the size the zoom gave it. Bounds and centre,
        // not frame: the picture carries a transform while it is zoomed, and a frame then means nothing.
        if zoomScale == minimumZoomScale, picture.bounds.size != bounds.size {
            picture.bounds = CGRect(origin: .zero, size: bounds.size)
            picture.center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            contentSize = bounds.size
        }
        centre()
    }

    /// Where the picture itself shows inside its view (its shape fitted in, without the bars beside it).
    var shownRect: CGRect {
        guard let size = picture.image?.size, size.width > 0, size.height > 0 else { return picture.bounds }
        let box = picture.bounds
        let scale = min(box.width / size.width, box.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - shown.width / 2, y: box.midY - shown.height / 2, width: shown.width, height: shown.height)
    }

    /// Keeps a picture smaller than the screen in its middle.
    func centre() {
        let x = max((bounds.width - contentSize.width) / 2, 0)
        let y = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}
