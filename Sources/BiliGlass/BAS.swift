import Foundation

// Independent implementation of the public BAS language specification.
// No JavaScript execution, web renderer, external font loading, or script side effects.
indirect enum BASValue: Equatable, Sendable {
  case number(Double, percent: Bool = false), string(String), reference(String)
  case object(String, [String: BASValue]), array([BASValue])
  var scalar: Double { if case .number(let n, _) = self { return n }; return 0 }
  var text: String {
    switch self { case .string(let s), .reference(let s): return s; default: return "" }
  }
  func resolved(_ reference: Double) -> Double {
    if case .number(let n, let percent) = self { return percent ? n * reference / 100 : n }
    return 0
  }
  func substitute(_ args: [String: BASValue]) -> BASValue {
    switch self {
    case .reference(let s): return args[s] ?? self
    case .array(let a): return .array(a.map { $0.substitute(args) })
    case .object(let k, let p): return .object(k, p.mapValues { $0.substitute(args) })
    default: return self
    }
  }
}
struct BASChange: Sendable {
  let start: Double
  let duration: Double
  let from: BASValue
  let to: BASValue
  let easing: String
}
struct BASNode: Sendable {
  let name: String
  let kind: String
  var properties: [String: BASValue]
  var tracks: [String: [BASChange]] = [:]
  var duration: Double = 4
  func values(at time: Double, size: CGSize) -> [String: BASValue] {
    var result = properties
    for (key, track) in tracks {
      var low = 0, high = track.count
      while low < high { let mid = (low+high)/2; if track[mid].start <= time { low = mid+1 } else { high = mid } }
      guard low > 0 else { continue }
      let change = track[low-1]
      result[key] = BASScene.interpolate(change, key: key, time: time, size: size)
    }
    return result
  }
}
struct BASScene: Sendable {
  var nodes: [BASNode]
  var duration: Double { nodes.map(\.duration).max() ?? 0 }
  static let transformKeys: Set<String> = ["x", "y", "rotateX", "rotateY", "rotateZ", "scale"]
  static let continuous: Set<String> = transformKeys.union(["alpha", "color"])
  static let mutable: Set<String> = continuous.union(["content", "text", "fontSize"])
  static func defaultValue(_ key: String) -> BASValue {
    switch key {
    case "alpha", "scale": return .number(1)
    case "fontSize": return .number(25)
    case "color": return .number(0xFFFFFF)
    default: return .number(0)
    }
  }
  static func eased(_ t: Double, _ name: String) -> Double {
    let t = min(1, max(0, t))
    // CSS cubic-bezier curves. Binary inversion is bounded and seek-independent.
    let control: (Double,Double,Double,Double)
    switch name {
    case "ease": control = (0.25,0.1,0.25,1)
    case "ease-in": control = (0.42,0,1,1)
    case "ease-out": control = (0,0,0.58,1)
    case "ease-in-out": control = (0.42,0,0.58,1)
    default: return t
    }
    func cubic(_ p: Double, _ a: Double, _ b: Double) -> Double {
      3 * (1-p) * (1-p) * p * a + 3 * (1-p) * p * p * b + p*p*p
    }
    var low = 0.0, high = 1.0
    for _ in 0..<12 { let mid = (low+high)/2; if cubic(mid,control.0,control.2) < t { low = mid } else { high = mid } }
    return cubic((low+high)/2,control.1,control.3)
  }
  static func interpolate(_ c: BASChange, key: String, time: Double, size: CGSize) -> BASValue {
    guard continuous.contains(key), case .number = c.to, case .number = c.from else { return c.to }
    let p = eased(c.duration > 0 ? (time-c.start)/c.duration : 1, c.easing)
    if key == "color" {
      let a = Int(c.from.scalar), b = Int(c.to.scalar)
      var color = 0
      for shift in [0,8,16] { color |= Int((Double((a>>shift)&255) * (1-p) + Double((b>>shift)&255) * p).rounded()) << shift }
      return .number(Double(color))
    }
    // Preserve percent units when possible; mixed units use current viewport/parent dimensions.
    if case .number(let a, let ap) = c.from, case .number(let b, let bp) = c.to, ap == bp {
      return .number(a + (b-a)*p, percent: ap)
    }
    let reference = key == "y" ? size.height : size.width
    let a = c.from.resolved(reference), b = c.to.resolved(reference)
    return .number(a + (b-a)*p)
  }
}

struct BASParser {
  enum Token: Equatable { case word(String), string(String), number(Double), symbol(Character), end }
  struct Template { let kind: String; let parameters: [(String,BASValue)]; let properties: [String:BASValue] }
  struct SetCommand { let name: String; let properties: [String:BASValue]; let start: Double; let duration: Double; let easing: String }
  private var tokens: [Token] = []
  private var i = 0
  private var templates: [String:Template] = [:]
  private var nodes: [BASNode] = []
  private var index: [String:Int] = [:]
  private var commands: [SetCommand] = []
  private var depth = 0
  private func failure(_ text: String) -> BiliError { BiliError(text: "BAS：\(text)（标记 \(i)）") }
  init(_ source: String) throws {
    guard source.utf8.count <= 16 * 1024 * 1024 else { throw BiliError(text: "BAS 脚本过大") }
    let chars = Array(source.unicodeScalars); var pos = 0
    func isLetter(_ c: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(c) || c == "_" || c == "$" }
    func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
    while pos < chars.count {
      if tokens.count > 500_000 { throw BiliError(text: "BAS 脚本过于复杂") }
      let c = chars[pos]
      if CharacterSet.whitespacesAndNewlines.contains(c) { pos += 1; continue }
      if c == "/", pos+1 < chars.count, chars[pos+1] == "/" {
        while pos < chars.count && chars[pos] != "\n" { pos += 1 }; continue
      }
      if c == "\"" {
        let start = pos; pos += 1; var escaped = false
        while pos < chars.count {
          let next = chars[pos]; pos += 1
          if next == "\"" && !escaped { break }
          if next == "\\" && !escaped { escaped = true } else { escaped = false }
        }
        let raw = String(String.UnicodeScalarView(chars[start..<pos]))
        guard let data = ("["+raw+"]").data(using:.utf8), let value = (try? JSONSerialization.jsonObject(with:data)) as? [String], let value = value.first else { throw BiliError(text:"BAS 字符串无效") }
        tokens.append(.string(value)); continue
      }
      if isDigit(c) || c == "." || c == "-" || c == "+" {
        let start = pos; pos += 1
        if c == "0", pos < chars.count, chars[pos] == "x" || chars[pos] == "X" {
          pos += 1; let digits = pos
          while pos < chars.count && CharacterSet(charactersIn:"0123456789abcdefABCDEF").contains(chars[pos]) { pos += 1 }
          guard let n = UInt64(String(String.UnicodeScalarView(chars[digits..<pos])),radix:16), n <= 0xFFFFFFFF else { throw BiliError(text:"BAS 色值无效") }
          tokens.append(.number(Double(n))); continue
        }
        while pos < chars.count && (isDigit(chars[pos]) || chars[pos] == ".") { pos += 1 }
        if pos < chars.count && (chars[pos] == "e" || chars[pos] == "E") {
          pos += 1; if pos < chars.count && (chars[pos] == "-" || chars[pos] == "+") { pos += 1 }
          while pos < chars.count && isDigit(chars[pos]) { pos += 1 }
        }
        guard let n = Double(String(String.UnicodeScalarView(chars[start..<pos]))), n.isFinite, abs(n) <= 1e12 else { throw BiliError(text:"BAS 数值无效") }
        tokens.append(.number(n)); continue
      }
      if case .number = tokens.last {
        let suffix = String(String.UnicodeScalarView(chars[pos..<min(chars.count,pos+3)]))
        if let unit = ["ms","s","m","h"].first(where: { suffix.hasPrefix($0) && (suffix.count == $0.count || !isLetter(Array(suffix.unicodeScalars)[$0.count])) }) {
          tokens.append(.word(unit)); pos += unit.count; continue
        }
      }
      if isLetter(c) {
        let start = pos; pos += 1
        while pos < chars.count && (isLetter(chars[pos]) || isDigit(chars[pos])) { pos += 1 }
        tokens.append(.word(String(String.UnicodeScalarView(chars[start..<pos])))); continue
      }
      guard "{}()[]=,;%".unicodeScalars.contains(c) else { throw BiliError(text:"BAS 包含不支持的语法") }
      tokens.append(.symbol(Character(c))); pos += 1
    }
    tokens.append(.end)
  }
  private var current: Token { tokens[min(i,tokens.count-1)] }
  @discardableResult private mutating func take(_ t: Token) -> Bool { if current == t { i += 1; return true }; return false }
  private mutating func expect(_ t: Token) throws { guard take(t) else { throw failure("语法不完整") } }
  private mutating func word() throws -> String { guard case .word(let s) = current else { throw failure("缺少名称") }; i += 1; return s }
  private mutating func separators() { while take(.symbol(",")) || take(.symbol(";")) {} }
  private mutating func value() throws -> BASValue {
    depth += 1; defer { depth -= 1 }; guard depth <= 32 else { throw failure("嵌套过深") }
    switch current {
    case .number(let n):
      i += 1
      if take(.symbol("%")) { return .number(n,percent:true) }
      let units: [String:Double] = ["ms":0.001,"s":1,"m":60,"h":3600]
      if case .word(let unit) = current, let multiple = units[unit] {
        i += 1; var time = n * multiple
        while case .number(let extra) = current, i+1 < tokens.count,
          case .word(let nextUnit) = tokens[i+1], let scale = units[nextUnit] {
          time += extra * scale; i += 2
        }
        return .number(time)
      }
      return .number(n)
    case .string(let s): i += 1; return .string(s)
    case .word(let s):
      i += 1
      if current == .symbol("{") { return .object(s,try properties()) }
      return .reference(s)
    case .symbol("["):
      i += 1; var values:[BASValue] = []
      while !take(.symbol("]")) { guard values.count < 16 else { throw failure("数组过长") }; values.append(try value()); separators() }
      return .array(values)
    default: throw failure("属性值无效")
    }
  }
  private mutating func properties() throws -> [String:BASValue] {
    try expect(.symbol("{")); var result:[String:BASValue] = [:]
    while !take(.symbol("}")) { let key = try word(); try expect(.symbol("=")); result[key] = try value(); separators() }
    return result
  }
  private mutating func add(_ name: String, _ kind: String, _ props: [String:BASValue]) throws {
    guard nodes.count < 10_000, index[name] == nil, ["text","path","button"].contains(kind) else { throw failure("元素定义无效或过多") }
    index[name] = nodes.count; nodes.append(BASNode(name:name,kind:kind,properties:props))
  }
  private mutating func instance(_ name: String) throws {
    let wrapped = take(.symbol("(")); let base = try word()
    if let template = templates[base], take(.symbol("(")) {
      var args = Dictionary(uniqueKeysWithValues:template.parameters); var position = 0
      while !take(.symbol(")")) {
        var key: String
        if case .word(let k) = current, tokens[i+1] == .symbol("=") { key = k; i += 2 }
        else { guard position < template.parameters.count else { throw failure("参数过多") }; key = template.parameters[position].0 }
        args[key] = try value(); position += 1; separators()
      }
      try add(name,template.kind,template.properties.mapValues { $0.substitute(args) })
    } else {
      let props = try properties()
      if let existing = index[base] { try add(name,nodes[existing].kind,nodes[existing].properties.merging(props){_,b in b}) }
      else { try add(name,base,props) }
    }
    if wrapped { try expect(.symbol(")")) }
  }
  private mutating func expression(start: Double, level: Int = 0, chain: Bool = true) throws -> Double {
    guard level < 32, commands.count < 50_000 else { throw failure("动画过于复杂") }
    var end = start
    if take(.symbol("{")) {
      while !take(.symbol("}")) { end = max(end,try expression(start:start,level:level+1)); separators() }
    } else {
      try expect(.word("set")); let name: String
      if current == .symbol("(") { name = "_anonymous_\(nodes.count)"; try instance(name) } else { name = try word() }
      let props = try properties(); let duration = try value().scalar
      guard duration >= 0, duration <= 86400 else { throw failure("动画时长无效") }
      var easing = "linear"
      if take(.symbol(",")) { easing = try value().text }
      commands.append(SetCommand(name:name,properties:props,start:start,duration:duration,easing:easing)); end += duration
    }
    while chain && take(.word("then")) { end = try expression(start:end,level:level,chain:false) }
    return end
  }
  mutating func parse() throws -> BASScene {
    while current != .end {
      separators(); if current == .end { break }
      if take(.word("def")) {
        let kind = try word(), name = try word()
        if take(.symbol("(")) {
          var parameters:[(String,BASValue)] = []
          while !take(.symbol(")")) {
            let key = try word(); let v: BASValue = take(.symbol("=")) ? try value() : .number(0)
            guard !parameters.contains(where: { $0.0 == key }) else { throw failure("模板参数重复") }
            parameters.append((key,v)); separators()
          }
          templates[name] = Template(kind:kind,parameters:parameters,properties:try properties())
        } else { try add(name,kind,try properties()) }
      } else if take(.word("let")) { let name = try word(); try expect(.symbol("=")); try instance(name) }
      else { _ = try expression(start:0) }
    }
    // Resolve overlap by source order before compiling property tracks. An entire
    // transform channel is superseded, matching BAS's documented parallel semantics.
    var accepted:[String:[SetCommand]] = [:]
    for c in commands {
      guard index[c.name] != nil else { throw failure("动画引用了不存在的元素") }
      var previous = accepted[c.name] ?? []
      for p in previous.indices {
        let old = previous[p]
        if old.start < c.start+c.duration && c.start < old.start+old.duration || old.start == c.start {
          var properties = old.properties
          let keys = Set(c.properties.keys)
          for key in keys { properties.removeValue(forKey:key) }
          if !keys.isDisjoint(with:BASScene.transformKeys) { for key in BASScene.transformKeys { properties.removeValue(forKey:key) } }
          previous[p] = SetCommand(name:old.name,properties:properties,start:old.start,duration:old.duration,easing:old.easing)
        }
      }
      previous.append(c); accepted[c.name] = previous
    }
    for n in nodes.indices {
      let cmds = (accepted[nodes[n].name] ?? []).sorted { $0.start < $1.start }
      let end = cmds.map { $0.start+$0.duration }.max() ?? 4
      nodes[n].duration = min(86400,max(0,nodes[n].properties["duration"]?.scalar ?? end))
      for c in cmds {
        for (key,raw) in c.properties where BASScene.mutable.contains(key) {
          var value = raw, easing = c.easing
          if case .array(let values) = raw, let first = values.first { value = first; if values.count > 1 { easing = values[1].text } }
          let from = nodes[n].tracks[key]?.last?.to ?? nodes[n].properties[key] ?? BASScene.defaultValue(key)
          nodes[n].tracks[key,default:[]].append(BASChange(start:c.start,duration:c.duration,from:from,to:value,easing:easing))
        }
      }
    }
    return BASScene(nodes:nodes)
  }
}
