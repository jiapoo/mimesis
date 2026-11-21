import StoreKit
import SwiftUI

/// Mimesis Pro: one purchase (`com.ljworkshop.mimesis.pro`, non-consumable, Family Sharing) that unlocks
/// Pro on every device of the account (universal purchase). Checked on the device with StoreKit 2, no
/// server: the transactions StoreKit holds for this Apple ID say whether it's been bought.
@MainActor @Observable
public final class ProStore {
    public static let shared = ProStore()
    public static let productID = "com.ljworkshop.mimesis.pro"

    /// Bought (by this Apple ID or someone in its family), and not refunded.
    public private(set) var isPro = false
    private var updates: Task<Void, Never>?

    private init() {
        // Purchases made elsewhere (another device, a family member, a refund) arrive here.
        updates = Task { [weak self] in
            for await _ in Transaction.updates { await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Reads what this Apple ID owns now.
    public func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
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
