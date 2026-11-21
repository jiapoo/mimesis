import StoreKit
import SwiftUI

/// What Mimesis Pro adds, each with what the Pro sheet says when that was what was tapped.
public enum ProFeature: String, Identifiable, CaseIterable, Sendable {
    case cutout, stroMotion, skeleton, report, takes, cleanExport
    public var id: Self { self }

    var symbol: String {
        switch self {
        case .cutout: "person.crop.rectangle"
        case .stroMotion: "figure.run"
        case .skeleton: "figure.arms.open"
        case .report: "doc.richtext"
        case .takes: "calendar"
        case .cleanExport: "film"
        }
    }

    var title: String {
        switch self {
        case .cutout: String(localized: "The person cut out over the other clip")
        case .stroMotion: String(localized: "StroMotion")
        case .skeleton: String(localized: "The skeleton, joint angles and their graphs")
        case .report: String(localized: "The PDF report")
        case .takes: String(localized: "Progress over takes")
        case .cleanExport: String(localized: "Exports without the Mimesis mark")
        }
    }

    var detail: String {
        switch self {
        case .cutout: String(localized: "Only the player shows over your clip, picked from the others in frame, lined up and tinted.")
        case .stroMotion: String(localized: "One picture with the body at several moments of the movement.")
        case .skeleton: String(localized: "Follow the body, read elbow, shoulder, hip and knee angles, and compare A with B over time.")
        case .report: String(localized: "A PDF to share: every segment's key frames, drawings, angles and notes.")
        case .takes: String(localized: "The same movement filmed on different days, each against the same model.")
        case .cleanExport: String(localized: "Videos and pictures without “Mimesis” on them.")
        }
    }
}

/// Mimesis Pro: one purchase (`com.ljworkshop.mimesis.pro.unlock`, non-consumable, Family Sharing off) that unlocks
/// Pro on every device of the account (universal purchase). Checked on the device with StoreKit 2, no
/// server: the transactions StoreKit holds for this Apple ID say whether it's been bought.
@MainActor @Observable
public final class ProStore {
    public static let shared = ProStore()
    public static let productID = "com.ljworkshop.mimesis.pro.unlock"

    /// Bought (by this Apple ID or someone in its family), and not refunded.
    public private(set) var isPro = false
    /// The product, for its price in the person's own currency (nil until the App Store answers).
    public private(set) var product: Product?
    /// The Pro sheet is up, for this feature (or for Pro in general, from the menu).
    public var paywall: ProFeature?
    /// Showing the sheet from a menu, not a feature.
    public var showingPro = false
    /// Buying or restoring is under way.
    public private(set) var busy = false
    /// What went wrong buying or restoring, to say so.
    public var problem: String?
    private var updates: Task<Void, Never>?

    private init() {
        // Purchases made elsewhere (another device, a family member, a refund) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await refresh()
            await loadProduct()
        }
    }

    /// Pro, or the Pro sheet for `feature`: whether to go on. Every Pro button asks this first.
    @discardableResult
    public func allows(_ feature: ProFeature) -> Bool {
        if isPro { return true }
        paywall = feature
        return false
    }

    /// Reads what this Apple ID owns now.
    public func refresh() async {
        #if DEBUG
        // Debug only: `-ProForScreenshots YES` shows Pro without buying it (App Store screenshots).
        if UserDefaults.standard.bool(forKey: "ProForScreenshots") { isPro = true; return }
        #endif
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
        if owned { paywall = nil; showingPro = false }
    }

    public func loadProduct() async {
        product = try? await Product.products(for: [Self.productID]).first
    }

    public func buy() async {
        problem = nil
        if product == nil { await loadProduct() }
        guard let product else {
            problem = String(localized: "The App Store can't be reached. Check the connection and try again.")
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result { await transaction.finish() }
                await refresh()
            case .pending:
                problem = String(localized: "Waiting for approval (Ask to Buy). Pro unlocks as soon as it's approved.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Asks the App Store for this Apple ID's purchases again (a new device, a reinstall).
    public func restore() async {
        problem = nil
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if !isPro { problem = String(localized: "No Mimesis Pro purchase was found for this Apple ID.") }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The free version's mark, as an image `height` pixels tall overall, for exports and saved pictures.
    func markImage(forHeight height: CGFloat) -> CGImage? {
        let size = min(64, max(14, height * 0.042))
        let renderer = ImageRenderer(content:
            Text(verbatim: "Mimesis")
                .font(.system(size: size, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.45), radius: size * 0.12, y: size * 0.06)
                .padding(size * 0.2))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// `image` with the mark in its bottom right corner, if this isn't Pro.
    func stamped(_ image: CGImage) -> CGImage {
        guard !isPro, let mark = markImage(forHeight: CGFloat(image.height)) else { return image }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let inset = CGFloat(mark.height) * 0.55
        context.draw(mark, in: CGRect(x: CGFloat(width - mark.width) - inset, y: inset * 0.6,
                                      width: CGFloat(mark.width), height: CGFloat(mark.height)))
        return context.makeImage() ?? image
    }
}

/// The Pro sheet, when a Pro feature is tapped in the free version, or Mimesis Pro is chosen in a menu.
struct ProSheets: ViewModifier {
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { ProStore.shared.paywall }, set: { ProStore.shared.paywall = $0 })) { feature in
                ProSheet(feature: feature)
            }
            .sheet(isPresented: Binding(get: { ProStore.shared.showingPro }, set: { ProStore.shared.showingPro = $0 })) {
                ProSheet(feature: nil)
            }
    }
}

/// The Pro sheet: what was tapped, everything Pro adds, the price in the person's currency, Buy and
/// Restore. One purchase, no subscription.
struct ProSheet: View {
    /// The feature that was tapped (nil: opened from the menu).
    let feature: ProFeature?
    @Environment(\.dismiss) private var dismiss
    private var store: ProStore { ProStore.shared }

    var body: some View {
        // Scrolls where the screen is short (an iPhone on its side), so Buy and Restore are always reachable.
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Mimesis Pro")
                        .font(.system(size: 26, weight: .bold))
                    Text("One purchase, no subscription, on all your Apple devices.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            // What was tapped first, then the rest.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(([feature].compactMap { $0 } + ProFeature.allCases.filter { $0 != feature }), id: \.self) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item == feature ? Theme.onAccent : Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(item == feature ? Theme.accent : Theme.accent.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title).font(.system(size: 14, weight: .semibold))
                            Text(verbatim: item.detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Everything else stays free: comparing, syncing, slow motion, drawing, angles, snapshots, projects, live replay and exports.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = store.problem {
                Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isPro {
                Label("Mimesis Pro is unlocked on this Apple ID. Thank you!", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
            VStack(spacing: 10) {
                Button { Task { await store.buy() } } label: {
                    Group {
                        if store.busy {
                            ProgressView().controlSize(.small)
                        } else if let price = store.product?.displayPrice {
                            Text("Buy Mimesis Pro for \(price)")
                        } else {
                            Text("Buy Mimesis Pro")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.busy)
                .help("Buy Mimesis Pro: a one-time purchase")
                Button("Restore Purchases") { Task { await store.restore() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .disabled(store.busy)
                    .help("Already bought Mimesis Pro on this Apple ID? Unlock it here")
            }
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.card)
        .preferredColorScheme(.dark)
        .task { if store.product == nil { await store.loadProduct() } }

    }
}

/// "Mimesis" on the picture, as a broadcaster puts its name on a channel: the free version shows it on one
/// video (Pro removes it). Plain white letters with a soft shadow so they read on any picture; sized to
/// the picture, in its bottom right corner, above the timeline. It stays put while the video is zoomed or
/// moved, and it's in snapshots, which keep what's on screen.
struct MimesisMark: View {
    /// The video's own size, to find where the picture sits (fitted, centred) in the space.
    let videoSize: CGSize
    /// Kept clear at the bottom of the space, for the timeline over it.
    var bottomClearance: CGFloat = 96

    var body: some View {
        GeometryReader { space in
            let picture = Self.fitted(videoSize, in: CGRect(origin: .zero, size: space.size))
            let size = min(22, max(12, picture.height * 0.042))
            let inset = size * 0.9
            // The picture's corner, raised above the timeline where the picture reaches down to it.
            let bottom = min(picture.maxY, space.size.height - bottomClearance)
            Color.clear
                .frame(width: max(0, picture.width), height: max(0, bottom - picture.minY))
                .overlay(alignment: .bottomTrailing) {
                    Text(verbatim: "Mimesis")
                        .font(.system(size: size, weight: .semibold))
                        .kerning(-0.2)
                        .foregroundStyle(.white.opacity(0.88))
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .fixedSize()
                        .padding(.trailing, inset)
                        .padding(.bottom, inset * 0.7)
                }
                .offset(x: picture.minX, y: picture.minY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func fitted(_ video: CGSize, in rect: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return rect }
        let scale = min(rect.width / video.width, rect.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
