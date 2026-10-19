import AppKit
import AVFoundation

struct AdvancedDanmaku: Sendable {
  let text: String, fontName: String
  let duration: Double, delay: Double, movement: Double
  let start: CGPoint, end: CGPoint
  let alphaStart: Double, alphaEnd: Double, rotationZ: Double, rotationY: Double
  let shadow: Bool, linear: Bool
  let path: [CGPoint]
  init?(_ raw: String) {
    guard raw.utf8.count < 256_000, let data = raw.data(using:.utf8), let v = try? JSONSerialization.jsonObject(with:data) as? [Any], v.count >= 5, let text = v[4] as? String else { return nil }
    func number(_ i: Int, _ fallback: Double) -> Double {
      guard i < v.count else { return fallback }
      let n = (v[i] as? Double) ?? Double(v[i] as? String ?? "") ?? fallback
      return n.isFinite && abs(n) < 1e9 ? n : fallback
    }
    func bool(_ i: Int, _ fallback: Bool) -> Bool {
      guard i < v.count else { return fallback }
      if let b = v[i] as? Bool { return b }
      if let s = v[i] as? String { return s != "false" && s != "0" }
      return fallback
    }
    self.text = text.replacingOccurrences(of:"/n",with:"\n")
    duration = min(3600,max(0.001,number(3,4.5)))
    delay = max(0,number(10,0)/1000)
    movement = max(0,number(9,duration*1000)/1000)
    start = CGPoint(x:number(0,0),y:number(1,0)); end = CGPoint(x:number(7,start.x),y:number(8,start.y))
    let a = (v[2] as? String ?? "1-1").split(separator:"-").compactMap { Double($0) }
    alphaStart = min(1,max(0,a.first ?? 1)); alphaEnd = min(1,max(0,a.last ?? 1))
    rotationZ = number(5,0); rotationY = number(6,0)
    shadow = bool(11,true); fontName = v.count > 12 ? v[12] as? String ?? "" : ""
    linear = bool(13,true)
    if v.count > 14, let s = v[14] as? String {
      let numbers = s.split(whereSeparator: { "MLml, ".contains($0) }).compactMap { Double($0) }
      path = stride(from:0,to:max(0,numbers.count-1),by:2).prefix(4096).map { CGPoint(x:numbers[$0],y:numbers[$0+1]) }
    } else { path = [] }
  }
  func position(at time: Double, size: CGSize) -> CGPoint {
    var p = min(1,max(0,movement > 0 ? (time-delay)/movement : (time >= delay ? 1 : 0)))
    if !linear { p = 1 - (1-p)*(1-p) }
    let point: CGPoint
    if path.count > 1 {
      let lengths = zip(path,path.dropFirst()).map { hypot($1.x-$0.x,$1.y-$0.y) }
      var remaining = lengths.reduce(0,+)*p; var found = path.last!
      for idx in lengths.indices {
        if remaining <= lengths[idx] {
          let r = lengths[idx] > 0 ? remaining/lengths[idx] : 0
          found = CGPoint(x:path[idx].x+(path[idx+1].x-path[idx].x)*r,y:path[idx].y+(path[idx+1].y-path[idx].y)*r); break
        }
        remaining -= lengths[idx]
      }
      point = found
    } else { point = CGPoint(x:start.x+(end.x-start.x)*p,y:start.y+(end.y-start.y)*p) }
    let proportional = path.isEmpty && abs(start.x) <= 1 && abs(start.y) <= 1 && abs(end.x) <= 1 && abs(end.y) <= 1
    // Legacy coordinates use an aspect-fit 672×438 stage, including its letterbox.
    if proportional { return CGPoint(x:point.x*size.width,y:point.y*size.height) }
    let scale = min(size.width/672,size.height/438)
    return CGPoint(x:(size.width-672*scale)/2+point.x*scale,y:(size.height-438*scale)/2+point.y*scale)
  }
}

struct CompiledSpecial: Sendable {
  let item: Danmaku
  let advanced: AdvancedDanmaku?
  let bas: BASScene?
  var duration: Double { advanced?.duration ?? bas?.duration ?? 0 }
}
struct SpecialCompilation: Sendable {
  var scripts:[CompiledSpecial] = []
  var unsupported = 0
  static func compile(_ items:[Danmaku]) -> SpecialCompilation {
    var result = SpecialCompilation()
    for item in items where [7,8,9].contains(item.mode) {
      if Task.isCancelled { break }
      if item.mode == 7, let advanced = AdvancedDanmaku(item.text) {
        result.scripts.append(CompiledSpecial(item:item,advanced:advanced,bas:nil))
      } else if item.mode == 9 {
        do { var parser = try BASParser(item.text); let scene = try parser.parse(); result.scripts.append(CompiledSpecial(item:item,advanced:nil,bas:scene)) }
        catch { result.unsupported += 1 }
      } else { result.unsupported += 1 }
    }
    return result
  }
}

@MainActor final class SpecialDanmakuRenderer {
  let root = CALayer()
  private(set) var compilation = SpecialCompilation()
  private var layers:[String:CALayer] = [:]
  private var visualKeys:[String:String] = [:]
  private var geometries:[String:CGPath] = [:]
  private var indexedScenes: [String:[String:BASNode]] = [:]
  private var activeButtons:[(CALayer,BASValue)] = []
  var count: Int { layers.count }
  var activate: ((BASValue)->Void)?
  init() { root.isGeometryFlipped = true; root.masksToBounds = true }
  func replace(_ value: SpecialCompilation) {
    clear(); compilation = value; geometries = [:]
    indexedScenes = Dictionary(uniqueKeysWithValues: value.scripts.compactMap { script in
      guard let bas = script.bas else { return nil }
      return (script.item.id, Dictionary(uniqueKeysWithValues: bas.nodes.map { ($0.name,$0) }))
    })
  }
  func clear() { layers.values.forEach { $0.removeFromSuperlayer() }; layers = [:]; visualKeys = [:]; activeButtons = [] }
  func hit(_ point: CGPoint) -> BASValue? {
    for (layer,target) in activeButtons.reversed() where layer.opacity > 0.05 && !layer.isHidden {
      if layer.bounds.contains(layer.convert(point,from:root)) { return target }
    }
    return nil
  }
  func render(time: Double, size: CGSize, backingScale: CGFloat, opacity: Float) {
    guard !compilation.scripts.isEmpty || !layers.isEmpty else { return }
    root.bounds = CGRect(origin:.zero,size:size); root.position = .zero; root.anchorPoint = .zero
    var live = Set<String>(); activeButtons = []
    for compiled in compilation.scripts where time >= compiled.item.time && time < compiled.item.time+compiled.duration {
      let elapsed = time-compiled.item.time
      if let a = compiled.advanced {
        let id = compiled.item.id; live.insert(id)
        let layer = textLayer(id)
        let scale = min(size.width/672,size.height/438)
        let fontSize = min(512,max(1,Double(compiled.item.size)*scale))
        configureText(layer,id:id,text:a.text,fontName:a.fontName,size:fontSize,bold:true,color:compiled.item.color,stroke:a.shadow ? 1 : 0,strokeColor:0,shadow:a.shadow,backingScale:backingScale)
        layer.anchorPoint = .zero; layer.position = a.position(at:elapsed,size:size)
        layer.opacity = Float(a.alphaStart+(a.alphaEnd-a.alphaStart)*elapsed/a.duration)*opacity
        layer.transform = transform(x:0,y:a.rotationY,z:a.rotationZ,scale:1)
      }
      if let bas = compiled.bas {
        let prefix = compiled.item.id+":"
        let nodesByName = indexedScenes[compiled.item.id] ?? [:]
        var evaluated = Set<String>()
        func draw(_ node: BASNode, depth: Int) {
          guard depth < 32, elapsed < node.duration, live.count < 5000, !evaluated.contains(node.name) else { return }
          evaluated.insert(node.name)
          let id = prefix+node.name
          var parent = root
          let parentName = node.properties["parent"]?.text ?? ""
          if !parentName.isEmpty {
            guard let p = nodesByName[parentName], elapsed < p.duration else { return }
            draw(p,depth:depth+1)
            guard let existing = layers[prefix+parentName], live.contains(prefix+parentName) else { return }
            parent = existing
          }
          let reference = parent === root ? size : parent.bounds.size
          let values = node.values(at:elapsed,size:reference)
          func n(_ key:String,_ fallback:Double=0) -> Double { values[key]?.scalar ?? fallback }
          func dimension(_ key:String,_ fallback:Double=0) -> Double { values[key]?.resolved(key == "y" || key == "height" ? reference.height : reference.width) ?? fallback }
          guard n("alpha",1) > 0.0001 else { return }
          let layer: CALayer
          if node.kind == "path" {
            let shape: CAShapeLayer
            if let existing = layers[id] as? CAShapeLayer { shape = existing } else { shape = CAShapeLayer(); layers[id] = shape }
            layer = shape
            let pathString = values["d"]?.text ?? ""
            if geometries[id] == nil { geometries[id] = try? SVGPath.parse(pathString) }
            if let path = geometries[id] {
              let boxValues = (values["viewBox"]?.text ?? "").split(whereSeparator:{ $0 == " " || $0 == "," }).compactMap { Double($0) }
              let box = boxValues.count == 4 ? CGRect(x:boxValues[0],y:boxValues[1],width:max(0.001,boxValues[2]),height:max(0.001,boxValues[3])) : path.boundingBoxOfPath
              let width = max(0.001,dimension("width",max(1,box.width))), height = max(0.001,dimension("height",width * box.height/max(0.001,box.width)))
              var t = CGAffineTransform(scaleX:width/max(0.001,box.width),y:height/max(0.001,box.height)).translatedBy(x:-box.minX,y:-box.minY)
              let key = "\(width):\(height)"
              if visualKeys[id] != key { shape.path = path.copy(using:&t); visualKeys[id] = key }
              shape.bounds = CGRect(x:0,y:0,width:width,height:height)
              shape.fillColor = Self.color(Int(n("fillColor",0xFFFFFF)),alpha:n("fillAlpha",1)).cgColor
              shape.strokeColor = Self.color(Int(n("borderColor")),alpha:n("borderAlpha",1)).cgColor
              shape.lineWidth = min(100,max(0,n("borderWidth")))
            }
          } else {
            let text = textLayer(id); layer = text
            let isButton = node.kind == "button"
            let content = values[isButton ? "text" : "content"]?.text ?? ""
            let font = values["fontSize"]?.resolved(size.width) ?? 25
            configureText(text,id:id,text:content,fontName:values["fontFamily"]?.text ?? "",size:font,bold:n("bold",1) != 0,color:Int(n(isButton ? "textColor":"color",isButton ? 0:0xFFFFFF)),stroke:n("strokeWidth"),strokeColor:Int(n("strokeColor",0xFFFFFF)),shadow:n("textShadow",1) != 0,backingScale:backingScale)
            if values["width"] != nil || values["height"] != nil {
              text.bounds.size = CGSize(width:max(1,dimension("width",text.bounds.width)),height:max(1,dimension("height",text.bounds.height)))
            }
            if isButton {
              text.backgroundColor = Self.color(Int(n("fillColor",0xFFFFFF)),alpha:n("fillAlpha",1)).cgColor
              text.cornerRadius = 5
              if let target = values["target"] { activeButtons.append((text,target)) }
            }
          }
          if layer.superlayer !== parent { parent.addSublayer(layer) }
          layer.anchorPoint = CGPoint(x:n("anchorX"),y:n("anchorY"))
          layer.position = CGPoint(x:dimension("x"),y:dimension("y"))
          layer.zPosition = min(10000,max(-10000,n("zIndex")))
          layer.opacity = Float(min(1,max(0,n("alpha",1)))) * (parent === root ? opacity : 1)
          layer.transform = transform(x:n("rotateX"),y:n("rotateY"),z:n("rotateZ"),scale:n("scale",1))
          live.insert(id)
        }
        for node in bas.nodes { draw(node,depth:0) }
      }
    }
    for key in Array(layers.keys) where !live.contains(key) { layers.removeValue(forKey:key)?.removeFromSuperlayer(); visualKeys.removeValue(forKey:key) }
  }
  private func textLayer(_ id:String) -> CATextLayer {
    if let layer = layers[id] as? CATextLayer { return layer }
    let layer = CATextLayer(); layer.anchorPoint = .zero; root.addSublayer(layer); layers[id] = layer; return layer
  }
  private func configureText(_ layer:CATextLayer,id:String,text:String,fontName:String,size:Double,bold:Bool,color:Int,stroke:Double,strokeColor:Int,shadow:Bool,backingScale:CGFloat) {
    let size = min(512,max(1,size)); let key = "\(text):\(fontName):\(size):\(bold):\(color):\(stroke):\(strokeColor):\(shadow):\(backingScale)"
    guard visualKeys[id] != key else { return }; visualKeys[id] = key
    let font = NSFont(name:fontName,size:size) ?? NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular)
    var attributes: [NSAttributedString.Key:Any] = [.font:font,.foregroundColor:Self.color(color)]
    if stroke > 0 { attributes[.strokeColor] = Self.color(strokeColor); attributes[.strokeWidth] = -min(30,stroke/size*100) }
    if shadow {
      let textShadow = NSShadow(); textShadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
      textShadow.shadowBlurRadius = 1; textShadow.shadowOffset = CGSize(width: 0, height: -1)
      attributes[.shadow] = textShadow
    }
    let value = NSAttributedString(string:String(text.prefix(20000)),attributes:attributes)
    let measured = value.boundingRect(with:CGSize(width:16384,height:16384),options:[.usesLineFragmentOrigin,.usesFontLeading])
    layer.string = value; layer.contentsScale = backingScale
    layer.bounds = CGRect(x:0,y:0,width:ceil(measured.width)+4,height:ceil(measured.height)+4)
    layer.shadowOpacity = 0 // Shadow is part of the cached text bitmap.
  }
  private func transform(x:Double,y:Double,z:Double,scale:Double) -> CATransform3D {
    var t = CATransform3DIdentity; t.m34 = -1/1000
    t = CATransform3DRotate(t,CGFloat(z * .pi/180),0,0,1)
    t = CATransform3DRotate(t,CGFloat(y * .pi/180),0,1,0)
    t = CATransform3DRotate(t,CGFloat(x * .pi/180),1,0,0)
    return CATransform3DScale(t,CGFloat(scale),CGFloat(scale),1)
  }
  static func color(_ value:Int,alpha:Double=1) -> NSColor {
    NSColor(srgbRed:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,alpha:min(1,max(0,alpha)))
  }
}
