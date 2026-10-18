import SwiftUI
import AliyunTokenBarCore

// MARK: - 迷你 SVG path 解析器
//
// 把 SVG 的 d 字符串解析成 SwiftUI Path,按 viewBox(默认 24)等比缩放绘制进目标 rect。
// 覆盖 simple-icons 等品牌标实际用到的命令:M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z
// (绝对 + 相对,隐式重复按 SVG 规范提升命令)。坐标系与 SVG 一致(y 向下),无需翻转。
// 椭圆弧按 ≤90° 分段用三次贝塞尔近似(SwiftUI Path 无旋转椭圆弧 API)。

enum SVGPathParser {
    static func path(from d: String, in rect: CGRect, viewBox: CGFloat = 24) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / viewBox
        let ox = rect.minX + (rect.width - viewBox * scale) / 2
        let oy = rect.minY + (rect.height - viewBox * scale) / 2
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * scale, y: oy + y * scale)
        }

        let tokens = tokenize(d)
        var i = 0
        var cur = CGPoint.zero        // 当前点(viewBox 坐标)
        var subStart = CGPoint.zero   // 子路径起点(Z 回闭)
        var prevCmd: Character = " "
        var prevCubicCtrl: CGPoint?   // 上一条 C/S 的第二控制点(S 反射用)
        var prevQuadCtrl: CGPoint?    // 上一条 Q/T 的控制点(T 反射用)

        func arg() -> CGFloat { defer { i += 1 }; return tokens[i].num }
        func more() -> Bool { i < tokens.count && tokens[i].cmd == nil }

        while i < tokens.count {
            let cmd: Character
            if let c = tokens[i].cmd { cmd = c; i += 1 } else { cmd = prevCmd }
            guard more() || cmd == "Z" || cmd == "z" else { break }
            let rel = cmd.isLowercase
            switch cmd {
            case "M", "m":
                var x = arg(), y = arg()
                if rel { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y)
                path.move(to: P(cur.x, cur.y))
                subStart = cur
                prevCmd = rel ? "l" : "L"   // 隐式重复提升为 LineTo
            case "L", "l":
                var x = arg(), y = arg()
                if rel { x += cur.x; y += cur.y }
                cur = CGPoint(x: x, y: y)
                path.addLine(to: P(cur.x, cur.y))
            case "H", "h":
                var x = arg()
                if rel { x += cur.x }
                cur.x = x
                path.addLine(to: P(cur.x, cur.y))
            case "V", "v":
                var y = arg()
                if rel { y += cur.y }
                cur.y = y
                path.addLine(to: P(cur.x, cur.y))
            case "C", "c":
                var x1 = arg(), y1 = arg(), x2 = arg(), y2 = arg(), x = arg(), y = arg()
                if rel { x1 += cur.x; y1 += cur.y; x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
                path.addCurve(to: P(x, y), control1: P(x1, y1), control2: P(x2, y2))
                prevCubicCtrl = CGPoint(x: x2, y: y2)
                cur = CGPoint(x: x, y: y)
            case "S", "s":
                var x2 = arg(), y2 = arg(), x = arg(), y = arg()
                if rel { x2 += cur.x; y2 += cur.y; x += cur.x; y += cur.y }
                let c1 = prevCubicCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: P(x, y), control1: P(c1.x, c1.y), control2: P(x2, y2))
                prevCubicCtrl = CGPoint(x: x2, y: y2)
                cur = CGPoint(x: x, y: y)
            case "Q", "q":
                var x1 = arg(), y1 = arg(), x = arg(), y = arg()
                if rel { x1 += cur.x; y1 += cur.y; x += cur.x; y += cur.y }
                path.addQuadCurve(to: P(x, y), control: P(x1, y1))
                prevQuadCtrl = CGPoint(x: x1, y: y1)
                cur = CGPoint(x: x, y: y)
            case "T", "t":
                var x = arg(), y = arg()
                if rel { x += cur.x; y += cur.y }
                let c = prevQuadCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: P(x, y), control: P(c.x, c.y))
                prevQuadCtrl = c
                cur = CGPoint(x: x, y: y)
            case "A", "a":
                let rx = arg(), ry = arg(), rot = arg()
                let largeArc = arg() != 0, sweep = arg() != 0
                var x = arg(), y = arg()
                if rel { x += cur.x; y += cur.y }
                addArc(&path, from: cur, to: CGPoint(x: x, y: y), rx: rx, ry: ry,
                       rotationDeg: rot, largeArc: largeArc, sweep: sweep, P: P)
                prevCubicCtrl = nil
                cur = CGPoint(x: x, y: y)
            case "Z", "z":
                path.closeSubpath()
                cur = subStart
                prevCubicCtrl = nil
                prevQuadCtrl = nil
            default:
                break
            }
            if !"CcSsQqTt".contains(cmd) { prevCubicCtrl = nil }
            if !"QqTt".contains(cmd) { prevQuadCtrl = nil }
            if !"Mm".contains(cmd) { prevCmd = cmd }
        }
        return path
    }

    /// 椭圆弧(端点→中心参数化,按 SVG 规范 F.6;分段三次贝塞尔近似)。
    private static func addArc(_ path: inout Path, from start: CGPoint, to end: CGPoint,
                               rx inRx: CGFloat, ry inRy: CGFloat, rotationDeg: CGFloat,
                               largeArc: Bool, sweep: Bool,
                               P: (CGFloat, CGFloat) -> CGPoint) {
        var rx = abs(inRx), ry = abs(inRy)
        if rx < 1e-9 || ry < 1e-9 {
            path.addLine(to: P(end.x, end.y))
            return
        }
        let phi = rotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (start.x - end.x) / 2, dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let co = den < 1e-9 ? 0 : sign * sqrt(max(0, num / den))
        let cxp = co * (rx * y1p / ry)
        let cyp = co * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let a = acos(max(-1, min(1, dot / max(len, 1e-9))))
            return (ux * vy - uy * vx < 0) ? -a : a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }

        func point(_ t: CGFloat) -> CGPoint {
            let ct = cos(t), st = sin(t)
            return CGPoint(x: cx + rx * ct * cosPhi - ry * st * sinPhi,
                           y: cy + rx * ct * sinPhi + ry * st * cosPhi)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            let ct = cos(t), st = sin(t)
            return CGPoint(x: -rx * ct * sinPhi - ry * st * cosPhi,
                           y: -rx * ct * cosPhi + ry * st * sinPhi)
        }
        let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        for s in 1...segments {
            let t0 = theta1 + dtheta * CGFloat(s - 1) / CGFloat(segments)
            let t1 = theta1 + dtheta * CGFloat(s) / CGFloat(segments)
            let dt = t1 - t0
            let alpha = sin(dt) * (sqrt(4 + 3 * tan(dt / 2) * tan(dt / 2)) - 1) / 3
            let p0 = point(t0), p1 = point(t1)
            let d0 = deriv(t0), d1 = deriv(t1)
            path.addCurve(to: P(p1.x, p1.y),
                          control1: P(p0.x + alpha * d0.x, p0.y + alpha * d0.y),
                          control2: P(p1.x - alpha * d1.x, p1.y - alpha * d1.y))
        }
    }

    private struct Token {
        var cmd: Character?
        var num: CGFloat
    }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(d)
        var i = 0
        func isCmd(_ c: Character) -> Bool { "MmLlHhVvCcSsQqTtAaZz".contains(c) }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || c == "," { i += 1; continue }
            if isCmd(c) { tokens.append(Token(cmd: c, num: 0)); i += 1; continue }
            var s = ""
            while i < chars.count {
                let ch = chars[i]
                guard ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" else { break }
                // "-"/"+" 仅当处于指数中部时延续当前数,否则是新数的起点
                if (ch == "-" || ch == "+") && !s.isEmpty && !"eE".contains(s.last!) { break }
                // 第二个 "." 是新数的起点(SVG 优化路径常见 ".306.306" 无分隔连写)
                if ch == "." && s.contains(".") { break }
                s.append(ch)
                i += 1
            }
            if let v = Double(s) {
                tokens.append(Token(cmd: nil, num: CGFloat(v)))
            } else {
                i += 1   // 跳过无法解析的字符,保证鲁棒
            }
        }
        return tokens
    }
}

// MARK: - 品牌标记部件

/// 一个绘制部件:路径 + 填充/描边 + 颜色角色(main=品牌主色,accent=辅助色如 Kimi 蓝点)。
struct MarkPart {
    enum Style: Equatable {
        case fill
        case stroke(StrokeStyle)
    }
    enum Role {
        case main, accent
    }
    let path: Path
    let style: Style
    let role: Role

    @ViewBuilder func view(main: Color, accent: Color?) -> some View {
        let color = (role == .accent ? accent : nil) ?? main
        switch style {
        case .fill:
            path.fill(color)
        case .stroke(let style):
            path.stroke(color, style: style)
        }
    }
}

// MARK: - 真实品牌标记(几何取自官方 logo)

/// 各 Provider 的真实 logo 几何。菜单栏用 silhouette(单色,模板图取 alpha),
/// 面板 tab 用 mark(品牌色)。「本机」无品牌标,返回 nil 由调用方回落 SF Symbol。
enum BrandMark: String, CaseIterable {
    case aliyun, openCode, kimi, deepSeek, zhipu, mimo, minimax, ollama, stepfun

    // MARK: 官方单路径标(simple-icons,CC0;24×24 viewBox)

    enum PathData {
    static let deepseek =
        "M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.53"
        + "7.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.05"
        + "5-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393"
        + ".137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.8"
        + "28-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.0"
        + "03-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.2"
        + "31 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284"
        + " 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682"
        + "-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2"
        + " 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3"
        + ".101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.1"
        + "4-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7"
        + " 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48"
        + " 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113"
        + ".074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.2"
        + "5 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-"
        + ".156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1."
        + "146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45"

    static let minimax =
        "M11.43 3.92a.86.86 0 1 0-1.718 0v14.236a1.999 1.999 0 0 1-3.997 0V9.022a.86.86 0 1 0-1.718 0v3.87a1.999 1.999 "
        + "0 0 1-3.997 0V11.49a.57.57 0 0 1 1.139 0v1.404a.86.86 0 0 0 1.719 0V9.022a1.999 1.999 0 0 1 3.997 0v9.134a.86."
        + "86 0 0 0 1.719 0V3.92a1.998 1.998 0 1 1 3.996 0v11.788a.57.57 0 1 1-1.139 0zm10.572 3.105a2 2 0 0 0-1.999 1.99"
        + "7v7.63a.86.86 0 0 1-1.718 0V3.923a1.999 1.999 0 0 0-3.997 0v16.16a.86.86 0 0 1-1.719 0V18.08a.57.57 0 1 0-1.13"
        + "8 0v2a1.998 1.998 0 0 0 3.996 0V3.92a.86.86 0 0 1 1.719 0v12.73a1.999 1.999 0 0 0 3.996 0V9.023a.86.86 0 1 1 1"
        + ".72 0v6.686a.57.57 0 0 0 1.138 0V9.022a2 2 0 0 0-1.998-1.997"

    static let xiaomi =
        "M12 0C8.016 0 4.756.255 2.493 2.516.23 4.776 0 8.033 0 12.012c0 3.98.23 7.235 2.494 9.497C4.757 23.77 8.017 24"
        + " 12 24c3.983 0 7.243-.23 9.506-2.491C23.77 19.247 24 15.99 24 12.012c0-3.984-.233-7.243-2.502-9.504C19.234.252"
        + " 15.978 0 12 0zM4.906 7.405h5.624c1.47 0 3.007.068 3.764.827.746.746.827 2.233.83 3.676v4.54a.15.15 0 0 1-.152"
        + ".147h-1.947a.15.15 0 0 1-.152-.148V11.83c-.002-.806-.048-1.634-.464-2.051-.358-.36-1.026-.441-1.72-.458H7.158a"
        + ".15.15 0 0 0-.151.147v6.98a.15.15 0 0 1-.152.148H4.906a.15.15 0 0 1-.15-.148V7.554a.15.15 0 0 1 .15-.149zm12.1"
        + "31 0h1.949a.15.15 0 0 1 .15.15v8.892a.15.15 0 0 1-.15.148h-1.949a.15.15 0 0 1-.151-.148V7.554a.15.15 0 0 1 .15"
        + "1-.149zM8.92 10.948h2.046c.083 0 .15.066.15.147v5.352a.15.15 0 0 1-.15.148H8.92a.15.15 0 0 1-.152-.148v-5.352a"
        + ".15.15 0 0 1 .152-.147Z"

    static let ollama =
        "M16.361 10.26a.894.894 0 0 0-.558.47l-.072.148.001.207c0 .193.004.217.059.353.076.193.152.312.291.448.24.238.5"
        + "1.3.872.205a.86.86 0 0 0 .517-.436.752.752 0 0 0 .08-.498c-.064-.453-.33-.782-.724-.897a1.06 1.06 0 0 0-.466 0"
        + "zm-9.203.005c-.305.096-.533.32-.65.639a1.187 1.187 0 0 0-.06.52c.057.309.31.59.598.667.362.095.632.033.872-.20"
        + "5.14-.136.215-.255.291-.448.055-.136.059-.16.059-.353l.001-.207-.072-.148a.894.894 0 0 0-.565-.472 1.02 1.02 0"
        + " 0 0-.474.007Zm4.184 2c-.131.071-.223.25-.195.383.031.143.157.288.353.407.105.063.112.072.117.136.004.038-.01."
        + "146-.029.243-.02.094-.036.194-.036.222.002.074.07.195.143.253.064.052.076.054.255.059.164.005.198.001.264-.03."
        + "169-.082.212-.234.15-.525-.052-.243-.042-.28.087-.355.137-.08.281-.219.324-.314a.365.365 0 0 0-.175-.48.394.39"
        + "4 0 0 0-.181-.033c-.126 0-.207.03-.355.124l-.085.053-.053-.032c-.219-.13-.259-.145-.391-.143a.396.396 0 0 0-.1"
        + "93.032zm.39-2.195c-.373.036-.475.05-.654.086-.291.06-.68.195-.951.328-.94.46-1.589 1.226-1.787 2.114-.04.176-."
        + "045.234-.045.53 0 .294.005.357.043.524.264 1.16 1.332 2.017 2.714 2.173.3.033 1.596.033 1.896 0 1.11-.125 2.06"
        + "4-.727 2.493-1.571.114-.226.169-.372.22-.602.039-.167.044-.23.044-.523 0-.297-.005-.355-.045-.531-.288-1.29-1."
        + "539-2.304-3.072-2.497a6.873 6.873 0 0 0-.855-.031zm.645.937a3.283 3.283 0 0 1 1.44.514c.223.148.537.458.671.66"
        + "2.166.251.26.508.303.82.02.143.01.251-.043.482-.08.345-.332.705-.672.957a3.115 3.115 0 0 1-.689.348c-.382.122-"
        + ".632.144-1.525.138-.582-.006-.686-.01-.853-.042-.57-.107-1.022-.334-1.35-.68-.264-.28-.385-.535-.45-.946-.03-."
        + "192.025-.509.137-.776.136-.326.488-.73.836-.963.403-.269.934-.46 1.422-.512.187-.02.586-.02.773-.002zm-5.503-1"
        + "1a1.653 1.653 0 0 0-.683.298C5.617.74 5.173 1.666 4.985 2.819c-.07.436-.119 1.04-.119 1.503 0 .544.064 1.24.15"
        + "5 1.721.02.107.031.202.023.208a8.12 8.12 0 0 1-.187.152 5.324 5.324 0 0 0-.949 1.02 5.49 5.49 0 0 0-.94 2.339 "
        + "6.625 6.625 0 0 0-.023 1.357c.091.78.325 1.438.727 2.04l.13.195-.037.064c-.269.452-.498 1.105-.605 1.732-.084."
        + "496-.095.629-.095 1.294 0 .67.009.803.088 1.266.095.555.288 1.143.503 1.534.071.128.243.393.264.407.007.003-.0"
        + "14.067-.046.141a7.405 7.405 0 0 0-.548 1.873c-.062.417-.071.552-.071.991 0 .56.031.832.148 1.279L3.42 24h1.478"
        + "l-.05-.091c-.297-.552-.325-1.575-.068-2.597.117-.472.25-.819.498-1.296l.148-.29v-.177c0-.165-.003-.184-.057-.2"
        + "93a.915.915 0 0 0-.194-.25 1.74 1.74 0 0 1-.385-.543c-.424-.92-.506-2.286-.208-3.451.124-.486.329-.918.544-1.1"
        + "54a.787.787 0 0 0 .223-.531c0-.195-.07-.355-.224-.522a3.136 3.136 0 0 1-.817-1.729c-.14-.96.114-2.005.69-2.834"
        + ".563-.814 1.353-1.336 2.237-1.475.199-.033.57-.028.776.01.226.04.367.028.512-.041.179-.085.268-.19.374-.431.09"
        + "3-.215.165-.333.36-.576.234-.29.46-.489.822-.729.413-.27.884-.467 1.352-.561.17-.035.25-.04.569-.04.319 0 .398"
        + ".005.569.04a4.07 4.07 0 0 1 1.914.997c.117.109.398.457.488.602.034.057.095.177.132.267.105.241.195.346.374.43."
        + "14.068.286.082.503.045.343-.058.607-.053.943.016 1.144.23 2.14 1.173 2.581 2.437.385 1.108.276 2.267-.296 3.15"
        + "3-.097.15-.193.27-.333.419-.301.322-.301.722-.001 1.053.493.539.801 1.866.708 3.036-.062.772-.26 1.463-.533 1."
        + "854a2.096 2.096 0 0 1-.224.258.916.916 0 0 0-.194.25c-.054.109-.057.128-.057.293v.178l.148.29c.248.476.38.823."
        + "498 1.295.253 1.008.231 2.01-.059 2.581a.845.845 0 0 0-.044.098c0 .006.329.009.732.009h.73l.02-.074.036-.134c."
        + "019-.076.057-.3.088-.516.029-.217.029-1.016 0-1.258-.11-.875-.295-1.57-.597-2.226-.032-.074-.053-.138-.046-.14"
        + "1.008-.005.057-.074.108-.152.376-.569.607-1.284.724-2.228.031-.26.031-1.378 0-1.628-.083-.645-.182-1.082-.348-"
        + "1.525a6.083 6.083 0 0 0-.329-.7l-.038-.064.131-.194c.402-.604.636-1.262.727-2.04a6.625 6.625 0 0 0-.024-1.358 "
        + "5.512 5.512 0 0 0-.939-2.339 5.325 5.325 0 0 0-.95-1.02 8.097 8.097 0 0 1-.186-.152.692.692 0 0 1 .023-.208c.2"
        + "08-1.087.201-2.443-.017-3.503-.19-.924-.535-1.658-.98-2.082-.354-.338-.716-.482-1.15-.455-.996.059-1.8 1.205-2"
        + ".116 3.01a6.805 6.805 0 0 0-.097.726c0 .036-.007.066-.015.066a.96.96 0 0 1-.149-.078A4.857 4.857 0 0 0 12 3.03"
        + "c-.832 0-1.687.243-2.456.698a.958.958 0 0 1-.148.078c-.008 0-.015-.03-.015-.066a6.71 6.71 0 0 0-.097-.725C8.99"
        + "7 1.392 8.337.319 7.46.048a2.096 2.096 0 0 0-.585-.041Zm.293 1.402c.248.197.523.759.682 1.388.03.113.06.244.06"
        + "9.292.007.047.026.152.041.233.067.365.098.76.102 1.24l.002.475-.12.175-.118.178h-.278c-.324 0-.646.041-.954.12"
        + "4l-.238.06c-.033.007-.038-.003-.057-.144a8.438 8.438 0 0 1 .016-2.323c.124-.788.413-1.501.696-1.711.067-.05.07"
        + "9-.049.157.013zm9.825-.012c.17.126.358.46.498.888.28.854.36 2.028.212 3.145-.019.14-.024.151-.057.144l-.238-.0"
        + "6a3.693 3.693 0 0 0-.954-.124h-.278l-.119-.178-.119-.175.002-.474c.004-.669.066-1.19.214-1.772.157-.623.434-1."
        + "185.68-1.382.078-.062.09-.063.159-.012z"

    static let alibabacloud =
        "M3.996 4.517h5.291L8.01 6.324 4.153 7.506a1.668 1.668 0 0 0-1.165 1.601v5.786a1.668 1.668 0 0 0 1.165 1.6l3.85"
        + "7 1.183 1.277 1.807H3.996A3.996 3.996 0 0 1 0 15.487V8.513a3.996 3.996 0 0 1 3.996-3.996m16.008 0h-5.291l1.277"
        + " 1.807 3.857 1.182c.715.227 1.17.889 1.165 1.601v5.786a1.668 1.668 0 0 1-1.165 1.6l-3.857 1.183-1.277 1.807h5."
        + "291A3.996 3.996 0 0 0 24 15.487V8.513a3.996 3.996 0 0 0-3.996-3.996m-4.007 8.345H8.002v-1.804h7.995Z"

    /// Kimi 的 K:官方 216px 图标(kimi.moonshot.cn statics.kimi.ai)轮廓追踪 + RDP 简化,
    /// 24×24 viewBox。填充形(非笔画),保留官方圆角内Join与斜边。
    static let kimiK =
        "M6.56 6.11L8.44 6.11L8.44 11.33L8.67 11.56L8.78 11.56L11.78 8.56L11.89 8.56L12.33 8.11L12.33 8.0L12."
            + "44 8.0L12.56 7.78L12.78 7.67L13.0 7.44L13.0 7.33L13.22 7.22L13.33 7.0L13.44 7.0L13.67 6.78L13.67 6.6"
            + "7L13.78 6.67L14.11 6.33L14.11 6.22L14.33 6.11L17.11 6.11L17.0 6.33L14.78 8.56L14.67 8.56L14.56 8.78L"
            + "14.44 8.78L14.33 9.0L14.22 9.0L14.11 9.22L14.0 9.22L13.67 9.56L13.67 9.67L13.56 9.67L13.22 10.0L13.2"
            + "2 10.11L13.11 10.11L13.0 10.33L12.89 10.33L12.78 10.56L12.67 10.56L12.56 10.78L12.44 10.78L12.33 11."
            + "0L12.11 11.11L12.11 11.22L11.89 11.33L11.89 11.44L12.44 12.0L12.89 12.22L13.67 12.89L14.0 13.0L14.89"
            + " 13.78L15.22 13.89L15.67 14.33L15.78 14.33L16.33 14.78L16.56 14.78L16.67 14.89L16.89 14.89L17.0 15.0"
            + "L17.44 15.11L17.44 17.33L17.11 17.33L17.0 17.22L16.22 17.11L15.11 16.56L14.78 16.22L14.0 15.78L13.67"
            + " 15.44L13.56 15.44L13.22 15.11L13.11 15.11L12.67 14.67L12.22 14.44L10.56 13.11L10.33 13.11L8.44 15.0"
            + "L8.44 17.33L6.56 17.33L6.56 6.22Z"

    /// 智谱官方 Z:zhipuai.cn/logo.svg 锁定标左侧的标记(path 9/10/11:顶横+粗斜杠+底 foot),
    /// 32×27 viewBox(比 bigmodel favicon 的简版 Z 正统)。
    static let zhipuZ =
        "M16.5376 0.0307374L14.3326 3.13223C14.1617 3.37577 13.9331 3.57415 13.6667 3.71001C13.4004 3.84586 1"
            + "3.1045 3.91504 12.8048 3.9115H0.787598V0.015152H16.5376V0.0307374Z M31.5 0.0321655L12.6 26.5273H0L18"
            + ".9 0.0321655H31.5Z M14.9624 26.5272L17.1832 23.4101C17.3564 23.1689 17.5856 22.9723 17.8513 22.8368C"
            + "18.1171 22.7012 18.4119 22.6306 18.7109 22.6308H30.7124V26.5272H14.9624Z"
    }

    /// 品牌主色(与 ProviderBrand 的身份色一致)。
    var mainColor: Color {
        switch self {
        case .aliyun: return .atbBrandAliyun
        case .openCode: return .atbBrandOpenCode
        case .kimi: return .atbBrandKimi
        case .deepSeek: return .atbBrandDeepSeek
        case .zhipu: return .atbBrandZhipu
        case .mimo: return .atbBrandMiMo
        case .minimax: return .atbBrandMiniMax
        case .ollama: return .atbBrandOllama
        case .stepfun: return .atbBrandStepFun
        }
    }

    /// 辅助色:Kimi 的蓝点、阶跃方块阵的白色方块。
    var accentColor: Color? {
        switch self {
        case .kimi: return Color(red: 0.18, green: 0.49, blue: 0.96)
        case .stepfun: return .white
        default: return nil
        }
    }

    /// 剪影模式各部件的透明度(main/accent)。
    /// 默认 main 实心、accent 半透(Kimi:K 实心 + 蓝点半透);
    /// 阶跃反转——方块阵才是身份(实心),圆盘退后(35%),否则单色下方块并进实心盘。
    var silhouetteOpacities: (main: Double, accent: Double) {
        switch self {
        case .stepfun: return (main: 0.35, accent: 1.0)
        default: return (main: 1.0, accent: 0.5)
        }
    }

    // MARK: 几何(24×24 viewBox → rect)

    func parts(in rect: CGRect) -> [MarkPart] {
        switch self {
        case .deepSeek:
            return [MarkPart(path: SVGPathParser.path(from: PathData.deepseek, in: rect), style: .fill, role: .main)]
        case .minimax:
            return [MarkPart(path: SVGPathParser.path(from: PathData.minimax, in: rect), style: .fill, role: .main)]
        case .ollama:
            return [MarkPart(path: SVGPathParser.path(from: PathData.ollama, in: rect), style: .fill, role: .main)]
        case .mimo:
            return [MarkPart(path: SVGPathParser.path(from: PathData.xiaomi, in: rect), style: .fill, role: .main)]
        case .aliyun:
            return [MarkPart(path: SVGPathParser.path(from: PathData.alibabacloud, in: rect), style: .fill, role: .main)]
        case .kimi:
            // 官方 K(填充轮廓)+ 右上蓝点
            var dot = Path()
            dot.addEllipse(in: CGRect(x: rect.minX + 18.79 * rect.width / 24,
                                      y: rect.minY + 3.56 * rect.width / 24,
                                      width: 2.54 * rect.width / 24,
                                      height: 2.54 * rect.width / 24))
            return [
                MarkPart(path: SVGPathParser.path(from: PathData.kimiK, in: rect), style: .fill, role: .main),
                MarkPart(path: dot, style: .fill, role: .accent),
            ]
        case .zhipu:
            return [MarkPart(path: SVGPathParser.path(from: PathData.zhipuZ, in: rect, viewBox: 32),
                             style: .fill, role: .main)]
        case .openCode:
            return handOpenCode(in: rect)
        case .stepfun:
            return handStepFun(in: rect)
        }
    }

    // MARK: 手绘几何(几何源:官方 512px 图标 / favicon 等比描摹)



    /// OpenCode:方框环 + 左下内方块(取自 opencode.ai 官方 favicon 的标记层,去深色底)。
    private func handOpenCode(in rect: CGRect) -> [MarkPart] {
        let s = min(rect.width, rect.height) / 24
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        var ring = Path()
        ring.addRect(r(6, 4.5, 12, 15))
        // 内方块:原点 0.55 不透明度呼应官方灰 #5A5858
        var inner = Path()
        inner.addRect(r(9, 10.5, 6, 6))
        return [
            MarkPart(path: ring, style: .stroke(StrokeStyle(lineWidth: 3.4 * s, lineCap: .butt, lineJoin: .miter)), role: .main),
            MarkPart(path: inner, style: .fill, role: .main),
        ]
    }

    /// 阶跃星辰:蓝底白方块阵(5 块阶梯排布,取自 stepfun.com 官方 favicon)。
    private func handStepFun(in rect: CGRect) -> [MarkPart] {
        let s = min(rect.width, rect.height) / 24
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
        }
        var circle = Path()
        circle.addEllipse(in: r(0, 0, 24, 24))
        var squares = Path()
        for (x, y) in [(4.4, 15.2), (9.8, 15.2), (9.8, 9.8), (9.8, 4.4), (15.2, 4.4)] {
            squares.addRect(r(x, y, 4.4, 4.4))
        }
        return [
            MarkPart(path: circle, style: .fill, role: .main),
            MarkPart(path: squares, style: .fill, role: .accent),
        ]
    }

    // MARK: 渲染入口

    /// 面板用:品牌主色(+辅助色)。
    @ViewBuilder func mark(in rect: CGRect) -> some View {
        let parts = parts(in: rect)
        ZStack {
            ForEach(parts.indices, id: \.self) { idx in
                parts[idx].view(main: mainColor, accent: accentColor)
            }
        }
        .frame(width: rect.width, height: rect.height)
    }

    /// 单色剪影(模板图只取 alpha,系统自动适配明暗)。各部件透明度见 silhouetteOpacities。
    @ViewBuilder func silhouette(in rect: CGRect, tint: Color) -> some View {
        let parts = parts(in: rect)
        let op = silhouetteOpacities
        ZStack {
            ForEach(parts.indices, id: \.self) { idx in
                parts[idx].view(main: tint.opacity(op.main), accent: tint.opacity(op.accent))
            }
        }
        .frame(width: rect.width, height: rect.height)
    }
}

// MARK: - Provider → 品牌标记映射

extension ProviderKind {
    /// 真实品牌标记;「本机」无品牌标 → nil(调用方回落 SF Symbol)。
    var brandMark: BrandMark? {
        switch self {
        case .aliyun: return .aliyun
        case .openCode: return .openCode
        case .kimi: return .kimi
        case .deepSeek: return .deepSeek
        case .zhipu: return .zhipu
        case .mimo: return .mimo
        case .minimax: return .minimax
        case .ollama: return .ollama
        case .stepfun: return .stepfun
        case .system: return nil
        }
    }
}

extension MenuBarColumnKind {
    var brandMark: BrandMark? {
        switch self {
        case .aliyun: return .aliyun
        case .kimi: return .kimi
        case .openCode: return .openCode
        case .deepSeek: return .deepSeek
        case .zhipu: return .zhipu
        case .mimo: return .mimo
        case .minimax: return .minimax
        case .ollama: return .ollama
        case .stepfun: return .stepfun
        case .system: return nil
        }
    }
}
