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
    var inverted = false
    var brandIcon = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if brandIcon {
                brandRow
            } else {
                sparkleRow
            }
        }
        .accessibilityLabel(label.isEmpty ? "Thinking" : label)
        .onAppear {
            shine = false
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                shine = true
            }
        }
    }

    @State private var shine = false

    private var mark: CGFloat {
        iconSize ?? (brandIcon ? 72 : max(size + 2, 17))
    }

    private var sparkleRow: some View {
        let dim = inverted ? Color.white.opacity(0.28) : SyncTheme.ink.opacity(0.32)
        let bright = inverted ? Color.white : Color.white
        let row = HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: mark, weight: .semibold))
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: size, weight: .medium))
                    .lineLimit(1)
            }
        }
        return row
            .foregroundStyle(dim)
            .overlay {
                row
                    .foregroundStyle(bright)
                    .mask { shineMask }
                    .allowsHitTesting(false)
            }
    }

    private var lightOnDark: Bool {
        inverted || colorScheme == .dark
    }

    private var brandMark: some View {
        Image("BrandLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: mark, height: mark)
            .colorScheme(lightOnDark ? .dark : .light)
            .opacity(0.32)
            .overlay {
                Image("BrandLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: mark, height: mark)
                    .colorScheme(lightOnDark ? .dark : .light)
                    .mask { shineMask }
                    .allowsHitTesting(false)
            }
    }

    private var brandRow: some View {
        HStack(spacing: 10) {
            brandMark
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle((lightOnDark ? Color.white : SyncTheme.ink).opacity(0.72))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: label.isEmpty ? nil : .infinity)
    }

    private var shineMask: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let band = max(w * 0.4, 14)
            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.15),
                    .white,
                    .white.opacity(0.15),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band, height: h)
            .offset(x: shine ? w : -band)
        }
        .clipped()
    }
}
