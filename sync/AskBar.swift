import SwiftUI

struct AskLaunchRow: View {
    var title: String = "Ask"
    var subtitle: String = "Opens a thread"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SyncTheme.inkMuted)
            }
            Spacer()
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SyncTheme.inkMuted)
        }
        .foregroundStyle(SyncTheme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(SyncTheme.paperRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SyncTheme.line, lineWidth: 1)
        )
    }
}

enum ChatMarkdown {
    static func attributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let cleaned = raw.replacingOccurrences(of: "\\n", with: "\n")
        if let parsed = try? AttributedString(markdown: cleaned, options: options) {
            return parsed
        }
        return AttributedString(cleaned)
    }

    struct Rich: View {
        let raw: String
        var color: Color = SyncTheme.ink

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let text):
                        Text(ChatMarkdown.attributed(text))
                            .font(.system(size: 16))
                            .foregroundStyle(color)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    case .bullet(let level, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(color)
                                .frame(width: 14, alignment: .center)
                            Text(ChatMarkdown.attributed(text))
                                .font(.system(size: 16))
                                .foregroundStyle(color)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 12 + CGFloat(level) * 20)
                    }
                }
            }
        }

        private var blocks: [Piece] {
            ChatMarkdown.pieces(raw)
        }
    }

    private enum Piece {
        case paragraph(String)
        case bullet(level: Int, text: String)
    }

    private static func pieces(_ raw: String) -> [Piece] {
        let text = raw.replacingOccurrences(of: "\\n", with: "\n")
        var out: [Piece] = []
        var paragraph: [String] = []

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: .newlines) {
            if let bullet = bulletLine(line) {
                flush()
                out.append(.bullet(level: bullet.level, text: bullet.text))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            paragraph.append(line)
        }
        flush()
        return out
    }

    private static func bulletLine(_ line: String) -> (level: Int, text: String)? {
        var spaces = 0
        var rest = Substring(line)
        while let first = rest.first {
            if first == " " { spaces += 1; rest.removeFirst(); continue }
            if first == "\t" { spaces += 4; rest.removeFirst(); continue }
            break
        }
        let body = String(rest)
        for prefix in ["- ", "* ", "• ", "– ", "— "] {
            if body.hasPrefix(prefix) {
                return (max(0, spaces / 2), String(body.dropFirst(prefix.count)))
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"^\d+[.)]\s+"#),
           let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let range = Range(match.range, in: body) {
            return (max(0, spaces / 2), String(body[range.upperBound...]))
        }
        return nil
    }
}

struct SparkleThinking: View {
    var label: String = "Thinking…"
    var size: CGFloat = 15
    var iconSize: CGFloat? = nil
    @State private var shine = false

    var body: some View {
        let mark = iconSize ?? max(size + 2, 17)
        let row = HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: mark, weight: .semibold))
            Text(label)
                .font(.system(size: size, weight: .medium))
        }
        row
            .foregroundStyle(SyncTheme.ink.opacity(0.32))
            .overlay {
                row
                    .foregroundStyle(Color.white)
                    .mask {
                        GeometryReader { geo in
                            let w = max(geo.size.width, 1)
                            let band = max(w * 0.38, 22)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.15), location: 0.28),
                                    .init(color: .white, location: 0.5),
                                    .init(color: .white.opacity(0.15), location: 0.72),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: shine ? w : -band)
                        }
                    }
                    .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    shine = true
                }
            }
            .accessibilityLabel(label)
    }
}
