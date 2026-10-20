import AppKit
import Foundation
import Testing
@testable import BiliGlass

struct SpecialDanmakuTests {
  @Test func legacySpecialPackageAddressesUpgradeToHTTPS() {
    #expect(API.specialDanmakuURL("http://i0.hdslb.com/bfs/dm/example.bin@2")?.absoluteString == "https://i0.hdslb.com/bfs/dm/example.bin@2")
    #expect(API.specialDanmakuURL("//i0.hdslb.com/bfs/dm/example.bin")?.scheme == "https")
    #expect(API.specialDanmakuURL("https://hdslb.com.example.org/payload") == nil)
    #expect(API.specialDanmakuURL("file:///tmp/payload") == nil)
  }
  func parse(_ text:String) throws -> BASScene { var p = try BASParser(text); return try p.parse() }
  @Test func serialParallelTimelineAndReverseSeekAreDeterministic() throws {
    let scene = try parse("""
      def text a { content="测试" x=0 alpha=1 }
      { set a {x=100%} 2s set a {alpha=0} 4s }
      then set a {x=0} 2s
      """)
    let node = try #require(scene.nodes.first)
    let size = CGSize(width:1000,height:500)
    #expect(scene.duration == 6)
    #expect(node.values(at:1,size:size)["x"]?.resolved(1000) == 500)
    #expect(node.values(at:5,size:size)["x"]?.resolved(1000) == 500)
    #expect(node.values(at:1,size:size)["alpha"]?.scalar == 0.75)
    #expect(node.values(at:1,size:size) == node.values(at:1,size:size))
  }
  @Test func templatesClonesCompoundTimesAndImmediateTextChanges() throws {
    let scene = try parse("""
      def text T(c="默认", x=0) { content=c x=x fontSize=5% }
      let a=T("测试",x=50%)
      let b=(a { content="复制" x=25% duration=1m2s500ms })
      set a {} 1s then set a {content="改变"} 2s
      """)
    #expect(scene.nodes.count == 2)
    #expect(scene.nodes[0].properties["content"]?.text == "测试")
    #expect(scene.nodes[1].duration == 62.5)
    #expect(scene.nodes[0].values(at:1.1,size:.zero)["content"]?.text == "改变")
  }
  @Test func transformOverlapDoesNotEraseIndependentOpacity() throws {
    let scene = try parse("""
      def text a {x=0 y=0 alpha=1}
      set a {x=100 y=50 alpha=0} 4s
      set a {x=200} 2s
      """)
    let values = scene.nodes[0].values(at:1,size:.zero)
    #expect(values["x"]?.scalar == 100)
    #expect(values["y"]?.scalar == 0)
    #expect(values["alpha"]?.scalar == 0.75)
  }
  @Test func advancedLifetimePathsRotationAndDelay() throws {
    let a = try #require(AdvancedDanmaku(#"[0,0,"1-0",30,"两行\n弹幕",30,45,672,438,2000,1000,true,"",1,"M0,0L100,0L100,100"]"#))
    #expect(a.duration == 30)
    #expect(a.rotationZ == 30)
    #expect(a.position(at:0,size:CGSize(width:672,height:438)) == .zero)
    #expect(a.position(at:2,size:CGSize(width:672,height:438)) == CGPoint(x:100,y:0))
    #expect(a.position(at:3,size:CGSize(width:672,height:438)) == CGPoint(x:100,y:100))
    #expect(a.text.contains("\n"))
  }
  @Test func vectorCurvesArcsAndRelativeCoordinates() throws {
    let p = try SVGPath.parse("M0,0 h100 v100 h-100 z M20 20 C30 0 60 0 80 20 S90 50 80 60 Q50 100 20 60 T20 20 M100 50 A50 50 0 1 1 0 50")
    #expect(p.boundingBoxOfPath.width >= 100)
    #expect(p.boundingBoxOfPath.height >= 100)
    #expect(throws:BiliError.self) { try SVGPath.parse("M 0 NaN") }
  }
  @Test func badScriptsAreBoundedAndDoNotDiscardOtherDanmaku() {
    let result = SpecialCompilation.compile([
      Danmaku(id:"bad",time:0,mode:9,size:25,color:0,text:"while(true) {}"),
      Danmaku(id:"good",time:0,mode:9,size:25,color:0,text:"def text a {content=\"原生\" duration=2s}"),
    ])
    #expect(result.unsupported == 1)
    #expect(result.scripts.count == 1)
    #expect(throws: BiliError.self) { try parse("def text T(a=1,a=2) { content=a }") }
  }
  @Test func fullscreenCommentsLeaveRoomForControls() {
    let items = (0..<40).map { Danmaku(id:"\($0)",time:0,mode:5,size:25,color:0,text:"顶部弹幕") }
    let plan = DanmakuLayout.prepare(items:items,size:CGSize(width:1280,height:720),scale:1,area:1,duration:8,time:0,topInset:76,bottomInset:100)
    #expect(!plan.isEmpty)
    #expect(plan.allSatisfy { $0.y >= 76 && $0.y + $0.height <= 620 })
  }
  @Test func reverseAndBottomDanmakuShareCollisionSpace() {
    let values = (0..<3).map { Danmaku(id:"\($0)",time:Double($0),mode:[1,6,4][$0],size:25,color:0,text:"避免相撞") }
    let plan = DanmakuLayout.prepare(items:values,size:CGSize(width:800,height:68),scale:1,area:1,duration:8,time:0,options:.init(avoidSubtitles:false))
    #expect(plan.count == 1)
  }
  @Test func mixedFontSizesNeverOverlapOrEnterSubtitleArea() {
    let items = (0..<30).map { Danmaku(id:"\($0)",time:0,mode:4,size:$0 % 2 == 0 ? 36 : 18,color:0xFFFFFF,text:"大字与小字") }
    let plan = DanmakuLayout.prepare(items:items,size:CGSize(width:1280,height:720),scale:2,area:1,duration:8,time:0)
      .sorted { $0.y < $1.y }
    #expect(plan.count > 1)
    for (a,b) in zip(plan, plan.dropFirst()) { #expect(a.y + a.height <= b.y) }
    #expect(plan.allSatisfy { $0.y + $0.height <= 720 * 0.85 })
  }
  @Test func filtersDoNotAffectAuthorPositionedScripts() {
    let items = [
      Danmaku(id:"a",time:0,mode:1,size:25,color:0xFFFFFF,text:"重复"),
      Danmaku(id:"b",time:1,mode:1,size:25,color:0xFFFFFF,text:"重复"),
      Danmaku(id:"c",time:1,mode:5,size:25,color:0xFFFFFF,text:"顶部"),
      Danmaku(id:"d",time:1,mode:1,size:25,color:0xFF0000,text:"红色"),
      Danmaku(id:"e",time:1,mode:1,size:25,color:0xFFFFFF,text:"屏蔽内容"),
      Danmaku(id:"f",time:1,mode:9,size:25,color:0xFFFFFF,text:"def text a {content=\"作品\"}"),
    ]
    let options = DanmakuDisplayOptions(top:false,colored:false,deduplicate:true,blockedWords:["屏蔽"])
    let plan = DanmakuLayout.prepare(items:items,size:CGSize(width:1280,height:720),scale:1,area:1,duration:8,time:0,options:options)
    #expect(plan.map(\.item.id) == ["a"])
    #expect(SpecialCompilation.compile(items).scripts.map(\.item.id) == ["f"])
  }
  @Test func SVGViewBoxPreservesAspectRatioAndScalesStrokes() {
    let layout = BASPathLayout(box:CGRect(x:0,y:0,width:4000,height:2250),width:1000,height:nil)
    #expect(layout.size == CGSize(width:1000,height:562.5))
    #expect(15 * layout.scale == 3.75)
    let square = BASPathLayout(box:CGRect(x:100,y:50,width:4000,height:2250),width:1000,height:1000)
    #expect(CGPoint(x:100,y:50).applying(square.transform) == CGPoint(x:0,y:218.75))
  }
  @Test @MainActor func SVGTopEdgeStaysAtTheTopWhenComposited() async throws {
    let renderer = SpecialDanmakuRenderer()
    renderer.replace(SpecialCompilation.compile([
      Danmaku(id:"top",time:0,mode:9,size:25,color:0,text:"""
        def path a {d="M10 10 H40 V30 H10 Z" viewBox="0 0 100 100" width=100 height=100 fillColor=0xff0000 borderWidth=0 duration=4s}
        """)
    ]))
    for _ in 0..<100 {
      renderer.render(time:1,size:CGSize(width:100,height:100),backingScale:1,opacity:1)
      if renderer.count > 0 { break }
      try await Task.sleep(for:.milliseconds(10))
    }
    #expect(renderer.count == 1)
    let context = try #require(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:0,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
    renderer.root.render(in:context)
    let bitmap = NSBitmapImageRep(cgImage:try #require(context.makeImage()))
    #expect(try #require(bitmap.colorAt(x:20,y:20)).alphaComponent > 0.9)
    #expect(try #require(bitmap.colorAt(x:20,y:80)).alphaComponent < 0.1)
  }
  @Test func incrementalCompilationKeepsEarlierPackagesAndPreparesUpcomingFrames() throws {
    let first = Danmaku(id:"first",time:0,mode:9,size:25,color:0,text:"""
      def path a {d="M0 0 L4000 0 L4000 2250 Z" viewBox="0 0 4000 2250" width=100% alpha=0}
      set a {} 1s then set a {alpha=1} 0ms then set a {} 1s then set a {alpha=0} 0ms
      """)
    let next = Danmaku(id:"second",time:60,mode:9,size:25,color:0,text:"def text t {content=\"下一包\"}")
    let old = SpecialCompilation.compile([first])
    let merged = SpecialCompilation.compile([first,next],reusing:old)
    #expect(merged.scripts.count == 2)
    let paths = BASGeometry.prepare(merged,time:0,existing:[])
    #expect(paths.count == 1)
    #expect(paths.first?.path.boundingBoxOfPath == CGRect(x:0,y:0,width:4000,height:2250))
    #expect(BASGeometry.prepare(merged,time:0,existing:Set(paths.map(\.id))).isEmpty)
    #expect(BASGeometry.prepare(merged,time:3,existing:[]).isEmpty)
  }
  @Test func sameCountUpdatesAndDeduplicationKeepSentComments() {
    let a = Danmaku(id:"1",time:1,mode:1,size:25,color:0,text:"一")
    let b = Danmaku(id:"2",time:2,mode:1,size:25,color:0,text:"二")
    #expect(DanmakuController.merged([b,a,b]) == [a,b])
  }
  @Test(.enabled(if:ProcessInfo.processInfo.environment["BILIGLASS_BAS_FIXTURE"] != nil)) func realBASPayload() throws {
    let path = ProcessInfo.processInfo.environment["BILIGLASS_BAS_FIXTURE"]!
    let items = try JSONDecoder().decode([Danmaku].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
    let scripts = items.filter { $0.mode == 9 }
    #expect(!scripts.isEmpty)
    var successes = 0
    for item in scripts {
      do { let scene = try parse(item.text); #expect(!scene.nodes.isEmpty); successes += 1 }
      catch { print("BAS parse failed",item.id,error.localizedDescription) }
    }
    print("BAS fixture parsed",successes,"of",scripts.count)
    #expect(successes == scripts.count)
  }
}
