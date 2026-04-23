// MessageBubbleView.swift
// Agentics
//
// All chat bubble UI in one place:
//   - BubbleShape       — the custom rounded path (user vs agent corner styles)
//   - AnimatedGradientBubble — the animated gradient fill/stroke behind each bubble
//   - MessageBubbleView — the full bubble row (avatar, text, timestamp)
//   - SystemNoticeView  — the divider shown between model sessions

import SwiftUI

// MARK: - BubbleShape

struct BubbleShape: Shape {
    let isUser: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 12; let smallR: CGFloat = 3; var path = Path()
        if isUser {
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - smallR))
            path.addArc(center: CGPoint(x: rect.maxX - smallR, y: rect.maxY - smallR), radius: smallR, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + smallR, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + smallR, y: rect.maxY - smallR), radius: smallR, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath(); return path
    }
}

// MARK: - AnimatedGradientBubble

struct AnimatedGradientBubble: View {
    let isUser: Bool
    let index: Int
    var isThinking: Bool = false
    var isLatest: Bool = false
    var shouldAnimate: Bool = true
    @State private var shift: CGFloat = 0

    var body: some View {
        let dir: (UnitPoint, UnitPoint) = (index % 2 == 0)
            ? (UnitPoint(x: 0, y: 0.5), UnitPoint(x: 1, y: 0.5))
            : (UnitPoint(x: 1, y: 0.5), UnitPoint(x: 0, y: 0.5))
        ZStack {
            if isUser {
                BubbleShape(isUser: true)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.90), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.90), location: max(0, min(1,  0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.90), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.90), location: max(0, min(1,  0.625 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.88), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ))
                BubbleShape(isUser: true).fill(.ultraThinMaterial.opacity(0.08))
                BubbleShape(isUser: true).stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.7)
            } else {
                BubbleShape(isUser: false)
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.16), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(0.16), location: max(0, min(1,  0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.14), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(0.16), location: max(0, min(1,  0.625 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.16), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ))
                BubbleShape(isUser: false).fill(.ultraThinMaterial.opacity(0.55))
                BubbleShape(isUser: false).stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(0.40), location: max(0, min(1, -0.125 + shift))),
                            .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(0.35), location: max(0, min(1,  0.375 + shift))),
                            .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(0.35), location: max(0, min(1,  0.875 + shift))),
                        ],
                        startPoint: dir.0, endPoint: dir.1
                    ), lineWidth: 0.6)
                if isThinking || isLatest {
                    let gleamOpacity: Double = isThinking ? 0.92 : 0.45
                    let gleamWidth: CGFloat  = isThinking ? 1.5  : 0.9
                    let glowOpacity: Double  = isThinking ? 0.5  : 0.2
                    BubbleShape(isUser: false).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 1.0,  green: 0.55, blue: 0.10).opacity(gleamOpacity), location: max(0, min(1, -0.125 + shift))),
                                .init(color: Color(red: 1.0,  green: 0.25, blue: 0.55).opacity(gleamOpacity), location: max(0, min(1,  0.125 + shift))),
                                .init(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(gleamOpacity), location: max(0, min(1,  0.375 + shift))),
                                .init(color: Color(red: 0.30, green: 0.55, blue: 1.00).opacity(gleamOpacity), location: max(0, min(1,  0.625 + shift))),
                                .init(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(gleamOpacity), location: max(0, min(1,  0.875 + shift))),
                            ],
                            startPoint: dir.0, endPoint: dir.1
                        ), lineWidth: gleamWidth)
                    .shadow(color: Color(red: 0.95, green: 0.15, blue: 0.65).opacity(glowOpacity), radius: 4)
                    .shadow(color: Color(red: 0.40, green: 0.78, blue: 1.00).opacity(glowOpacity * 0.8), radius: 6)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
            }
        }
        .onAppear {
            guard shouldAnimate, shift == 0 else { return }
            let delay = Double(index % 8) * 0.45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: isThinking ? 0.6 : 3.0).repeatForever(autoreverses: true)) {
                    shift = 0.25
                }
            }
        }
        .onChange(of: isThinking) { thinking in
            guard shouldAnimate else { return }
            shift = 0
            withAnimation(.easeInOut(duration: thinking ? 0.6 : 3.0).repeatForever(autoreverses: true)) {
                shift = 0.25
            }
        }
    }
}

// MARK: - MessageBubbleView

struct MessageBubbleView: View {
    let message: Message
    let agent: Agent
    let sideIndex: Int
    var isThinking: Bool = false
    var isLatest: Bool = false
    var shouldAnimate: Bool = true

    func markdownText(_ string: String) -> Text {
        if var attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            for run in attributed.runs {
                if run.link != nil {
                    attributed[run.range].foregroundColor = Color(red: 1.0, green: 0.25, blue: 0.55)
                    attributed[run.range].underlineStyle = .single
                }
            }
            return Text(attributed)
        }
        return Text(string)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    markdownText(message.content)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AnimatedGradientBubble(isUser: true, index: sideIndex, shouldAnimate: shouldAnimate))
                    Text(timeString(message.timestamp)).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }
            } else {
                Circle().fill(agent.avatarColor.opacity(0.15)).frame(width: 28, height: 28)
                    .overlay(Circle().stroke(agent.avatarColor.opacity(0.3), lineWidth: 0.5))
                    .overlay(Text(String(agent.name.prefix(1))).font(.system(size: 11, weight: .bold)).foregroundColor(agent.avatarColor))

                VStack(alignment: .leading, spacing: 3) {
                    markdownText(message.content.isEmpty ? " " : message.content)
                        .font(.system(size: 13)).foregroundColor(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(AnimatedGradientBubble(isUser: false, index: sideIndex, isThinking: isThinking, isLatest: isLatest, shouldAnimate: shouldAnimate))
                    Text(timeString(message.timestamp)).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
    }

    func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }
}

// MARK: - SystemNoticeView

struct SystemNoticeView: View {
    let content: String

    // First line is the model name, second line is the status
    private var lines: [String] { content.components(separatedBy: "\n") }
    private var headline: String { lines.first ?? content }
    private var statusLine: String? { lines.count > 1 ? lines[1] : nil }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)

            VStack(spacing: 2) {
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.45))
                if let status = statusLine {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(
                            status.contains("✓")
                                ? Color(red: 0.3, green: 0.85, blue: 0.5).opacity(0.75)
                                : Color.white.opacity(0.3)
                        )
                }
            }
            .fixedSize()
            .multilineTextAlignment(.center)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}
