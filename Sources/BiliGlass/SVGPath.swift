import CoreGraphics
import Foundation

/// Bounded SVG path parser for BAS vector artwork. Produces geometry only.
enum SVGPath {
  static func parse(_ source:String) throws -> CGPath {
    guard source.utf8.count <= 2_000_000 else { throw BiliError(text:"BAS 路径过大") }
    let scanner = Scanner(string:source)
    scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn:","))
    let path = CGMutablePath(); var command: Character = "M", previous: Character = "M"
    var point = CGPoint.zero, origin = CGPoint.zero, control = CGPoint.zero
    var count = 0
    func number() throws -> Double {
      guard let n = scanner.scanDouble(), n.isFinite, abs(n) < 1e9 else { throw BiliError(text:"BAS 路径坐标无效") }; return n
    }
    while !scanner.isAtEnd {
      count += 1; guard count < 100_000 else { throw BiliError(text:"BAS 路径过于复杂") }
      if let token = scanner.scanCharacters(from:.letters) {
        guard token.count == 1, let c = token.first, "MmLlHhVvCcSsQqTtAaZz".contains(c) else { throw BiliError(text:"BAS 路径指令无效") }
        command = c
      }
      let relative = command.isLowercase, key = command.uppercased()
      let base = relative ? point : .zero
      func pair() throws -> CGPoint { CGPoint(x:try number()+base.x,y:try number()+base.y) }
      switch key {
      case "M": point = try pair(); origin = point; path.move(to:point); command = relative ? "l":"L"
      case "L": point = try pair(); path.addLine(to:point)
      case "H": point.x = try number() + base.x; path.addLine(to:point)
      case "V": point.y = try number() + base.y; path.addLine(to:point)
      case "C": let c1 = try pair(), c2 = try pair(), end = try pair(); path.addCurve(to:end,control1:c1,control2:c2); control = c2; point = end
      case "S": let c1 = "CS".contains(previous.uppercased()) ? CGPoint(x:2*point.x-control.x,y:2*point.y-control.y):point; let c2 = try pair(), end = try pair(); path.addCurve(to:end,control1:c1,control2:c2); control = c2; point = end
      case "Q": let c = try pair(), end = try pair(); path.addQuadCurve(to:end,control:c); control = c; point = end
      case "T": let c = "QT".contains(previous.uppercased()) ? CGPoint(x:2*point.x-control.x,y:2*point.y-control.y):point; let end = try pair(); path.addQuadCurve(to:end,control:c); control = c; point = end
      case "A":
        let rx = try number(), ry = try number(), rotation = try number(), large = try number() != 0, sweep = try number() != 0, end = try pair()
        arc(path,from:point,to:end,rx:abs(rx),ry:abs(ry),rotation:rotation,large:large,sweep:sweep); point = end
      case "Z": path.closeSubpath(); point = origin; command = "M"
      default: throw BiliError(text:"BAS 路径指令不支持")
      }
      previous = Character(key)
    }
    return path
  }
  private static func arc(_ path:CGMutablePath,from start:CGPoint,to end:CGPoint,rx:Double,ry:Double,rotation:Double,large:Bool,sweep:Bool) {
    guard rx > 0, ry > 0, start != end else { path.addLine(to:end); return }
    let angle = rotation * .pi / 180, cosA = cos(angle), sinA = sin(angle)
    let dx = (start.x-end.x)/2, dy = (start.y-end.y)/2
    let x = cosA*dx+sinA*dy, y = -sinA*dx+cosA*dy
    let correction = max(1,sqrt(x*x/(rx*rx)+y*y/(ry*ry)))
    let rx = rx*correction, ry = ry*correction
    let denominator = rx*rx*y*y+ry*ry*x*x
    guard denominator > 0 else { path.addLine(to:end); return }
    let coefficient = (large == sweep ? -1.0:1.0)*sqrt(max(0,(rx*rx*ry*ry-denominator)/denominator))
    let cxp = coefficient*rx*y/ry, cyp = -coefficient*ry*x/rx
    let cx = cosA*cxp-sinA*cyp+(start.x+end.x)/2, cy = sinA*cxp+cosA*cyp+(start.y+end.y)/2
    let begin = atan2((y-cyp)/ry,(x-cxp)/rx)
    var delta = atan2((-y-cyp)/ry,(-x-cxp)/rx)-begin
    if !sweep && delta > 0 { delta -= 2 * .pi }; if sweep && delta < 0 { delta += 2 * .pi }
    let segments = max(1,Int(ceil(abs(delta)/(.pi/2))))
    func position(_ a:Double) -> CGPoint { CGPoint(x:cx+cosA*rx*cos(a)-sinA*ry*sin(a),y:cy+sinA*rx*cos(a)+cosA*ry*sin(a)) }
    func derivative(_ a:Double) -> CGPoint { CGPoint(x:-cosA*rx*sin(a)-sinA*ry*cos(a),y:-sinA*rx*sin(a)+cosA*ry*cos(a)) }
    for i in 0..<segments {
      let a = begin+delta*Double(i)/Double(segments), b = begin+delta*Double(i+1)/Double(segments), k = 4/3*tan((b-a)/4)
      let p = position(a), q = position(b), u = derivative(a), v = derivative(b)
      path.addCurve(to:q,control1:CGPoint(x:p.x+k*u.x,y:p.y+k*u.y),control2:CGPoint(x:q.x-k*v.x,y:q.y-k*v.y))
    }
  }
}
