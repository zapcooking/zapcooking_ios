import SwiftUI

/// Static concentric-rings rendering of the social graph. The user sits at the center,
/// top-15 first-degree follows form the inner ring, and top-64 second-degree (qualified)
/// pubkeys form the outer ring. Each second-degree node is positioned at the angle of
/// its strongest first-degree connector. Pan and pinch gestures move the whole canvas.
struct SocialGraphCanvas: View {
    let userPubkey: String
    let firstDegree: [GraphNode]      // pre-sorted by descending followerCount
    let secondDegree: [GraphNode]     // pre-sorted by descending followerCount
    /// 2nd-degree pubkey → its strongest 1st-degree connector pubkey. Used both to draw
    /// the connecting edge and to inherit the angular position of that connector.
    let strongestConnector: [String: String]
    let profiles: [String: ProfileData]
    let onTapNode: (GraphNode) -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r1 = min(geo.size.width, geo.size.height) * 0.25
            let r2 = min(geo.size.width, geo.size.height) * 0.45

            let firstAngles = computeFirstAngles(count: firstDegree.count)
            let firstPositions: [String: CGPoint] = Dictionary(uniqueKeysWithValues: firstDegree.enumerated().map { i, node in
                (node.pubkey, polar(center: center, radius: r1, angle: firstAngles[i]))
            })
            let firstAngleByPubkey: [String: Double] = Dictionary(uniqueKeysWithValues: firstDegree.enumerated().map { i, node in
                (node.pubkey, firstAngles[i])
            })
            let secondPositions: [String: CGPoint] = computeSecondPositions(
                center: center,
                radius: r2,
                firstAngleByPubkey: firstAngleByPubkey
            )

            ZStack {
                Canvas { ctx, _ in
                    let edgeColor = Color.wispSurfaceVariant.opacity(0.5)
                    var path = Path()
                    for node in firstDegree {
                        guard let p = firstPositions[node.pubkey] else { continue }
                        path.move(to: center)
                        path.addLine(to: p)
                    }
                    for node in secondDegree {
                        guard let p2 = secondPositions[node.pubkey] else { continue }
                        if let connector = strongestConnector[node.pubkey],
                           let p1 = firstPositions[connector] {
                            path.move(to: p1)
                            path.addLine(to: p2)
                        }
                    }
                    ctx.stroke(path, with: .color(edgeColor), lineWidth: 0.5)
                }

                CenterNode(profile: profiles[userPubkey])
                    .position(center)
                    .onTapGesture { /* tapping self is a no-op for now */ }

                ForEach(firstDegree, id: \.pubkey) { node in
                    if let p = firstPositions[node.pubkey] {
                        NodeAvatar(
                            profile: profiles[node.pubkey],
                            size: nodeSize(followerCount: node.followerCount, degree: 1)
                        )
                        .position(p)
                        .onTapGesture { onTapNode(node) }
                    }
                }
                ForEach(secondDegree, id: \.pubkey) { node in
                    if let p = secondPositions[node.pubkey] {
                        NodeAvatar(
                            profile: profiles[node.pubkey],
                            size: nodeSize(followerCount: node.followerCount, degree: 2)
                        )
                        .position(p)
                        .onTapGesture { onTapNode(node) }
                    }
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(0.5, min(3.0, lastScale * value))
                        }
                        .onEnded { _ in lastScale = scale },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    scale = 1.0; lastScale = 1.0
                    offset = .zero; lastOffset = .zero
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.wispBackground)
    }

    // MARK: - Layout

    private func computeFirstAngles(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let n = Double(count)
        return (0..<count).map { i in
            let t = Double(i) / n
            return 2 * Double.pi * t - Double.pi / 2
        }
    }

    private func computeSecondPositions(
        center: CGPoint,
        radius: CGFloat,
        firstAngleByPubkey: [String: Double]
    ) -> [String: CGPoint] {
        var bucket: [Double: Int] = [:]
        var out: [String: CGPoint] = [:]
        for node in secondDegree {
            let baseAngle: Double
            if let connector = strongestConnector[node.pubkey], let a = firstAngleByPubkey[connector] {
                baseAngle = a
            } else {
                baseAngle = Double.random(in: 0..<(2 * .pi))
            }
            let bucketIdx = bucket[baseAngle, default: 0]
            bucket[baseAngle] = bucketIdx + 1
            // Spread nodes that share a connector along a small fan around the connector's angle.
            let fanStep = 0.07
            let centered = Double(bucketIdx) - 2.0
            let angle = baseAngle + centered * fanStep
            out[node.pubkey] = polar(center: center, radius: radius, angle: angle)
        }
        return out
    }

    private func polar(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    private func nodeSize(followerCount: Int, degree: Int) -> CGFloat {
        let base: CGFloat = degree == 1 ? 28 : 18
        let maxR: CGFloat = degree == 1 ? 56 : 36
        let scale: CGFloat = degree == 1 ? 4 : 3
        let bonus = CGFloat(log2(Double(followerCount + 1))) * scale
        return min(base + bonus, maxR)
    }
}

struct GraphNode: Hashable {
    let pubkey: String
    /// For first-degree nodes: how many *other* of my follows follow them.
    /// For second-degree nodes: how many of my follows follow them.
    let followerCount: Int
}

private struct CenterNode: View {
    let profile: ProfileData?
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.wispPrimary, lineWidth: 2)
                .frame(width: 56, height: 56)
            CachedAvatarView(url: profile?.picture, size: 48, alwaysLoad: true)
        }
    }
}

private struct NodeAvatar: View {
    let profile: ProfileData?
    let size: CGFloat
    var body: some View {
        CachedAvatarView(url: profile?.picture, size: size)
            .overlay(Circle().stroke(Color.wispSurfaceVariant.opacity(0.6), lineWidth: 0.5))
    }
}
