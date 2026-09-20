import SwiftUI
import UIKit
import QuartzCore
import os

struct LinkPreviewView: View {
    let url: String
    @Environment(AppSettings.self) private var settings
    @State private var data: OpenGraphData?
    @State private var loaded = false

    var body: some View {
        Group {
            if let data {
                preview(data)
            } else if loaded {
                fallbackText
            } else {
                placeholder
            }
        }
        .task(id: url) {
            #if DEBUG
            PerfTrace.mark("linkPreview.task", url: url)
            #endif
            if let cached = await LinkPreviewService.shared.cached(url) {
                data = cached
                loaded = true
                return
            }
            #if DEBUG
            let t0 = CACurrentMediaTime()
            #endif
            data = await LinkPreviewService.shared.fetch(url)
            #if DEBUG
            mediaPerfLog.log("linkPreview.fetch \(Int((CACurrentMediaTime() - t0) * 1000), privacy: .public)ms hit=\(data != nil, privacy: .public) url=\(url, privacy: .public)")
            #endif
            loaded = true
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.wispSurfaceVariant.opacity(0.3))
            .frame(height: 80)
            .overlay { ProgressView() }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
    }

    private var fallbackText: some View {
        Button {
            if let u = URL(string: url) {
                UIApplication.shared.open(u)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url)
                    .font(.callout)
                    .foregroundStyle(Color.zapLink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.wispSurfaceVariant.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func preview(_ data: OpenGraphData) -> some View {
        Button {
            if let u = URL(string: url) {
                UIApplication.shared.open(u)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageUrl = data.image, let img = URL(string: imageUrl), settings.autoLoadMedia {
                    // Wrap the image in a fixed-height container so an
                    // `aspectRatio(.fill)` source (almost every OG image
                    // is wider than tall) can't render past 180pt and
                    // leave its overflow as live hit-test area above /
                    // below the card. `.clipped()` masks drawing but
                    // does NOT shrink the gesture region; without this
                    // wrapper a tap on the body line just above the card
                    // would land on the Button and open the URL.
                    Color.clear
                        .frame(height: 180)
                        .overlay {
                            AsyncImage(url: img) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure:
                                    EmptyView()
                                default:
                                    Color.wispSurfaceVariant.opacity(0.4)
                                        .overlay { ProgressView() }
                                }
                            }
                        }
                        .clipped()
                }

                // Human-readable hierarchy (ZapColors.swift): site name and
                // description gray, title white, and one link-tier line at
                // the foot carrying the domain and the action — so the raw
                // URL never has to appear when metadata resolved.
                VStack(alignment: .leading, spacing: 4) {
                    if let site = data.siteName, !site.isEmpty {
                        Text(site.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                    if let title = data.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let desc = data.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        if let host = domain(from: url) {
                            Text(host)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 3) {
                            Text("Open")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.zapLink)
                    }
                    .padding(.top, 4)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.wispSurfaceVariant.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Pin the gesture region to the visible rounded card so that
            // taps in the body text or gap immediately above the preview
            // fall through to the enclosing post NavigationLink instead
            // of opening the link.
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func domain(from url: String) -> String? {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "")
    }
}
