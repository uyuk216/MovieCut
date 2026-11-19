import XCTest
@testable import MovieCutCore

/// FCP XML(XMEML バージョン 4)の書き出し・読み込みと往復の検証。
/// 形式の根拠は Apple 公式「Final Cut Pro XML Interchange Format」(2009-02-04)。
/// 他社ソフト実機での読み込みは未検証で、ここで保証するのは
/// 「仕様どおりの構造であること」と「MovieCut 往復でカット・素材・基本変換が一致すること」。
final class FcpXmlTests: XCTestCase {

    // MARK: 助っ人

    private func clip(_ type: ClipType, src: String?, start: Double, duration: Double, offset: Double = 0) -> Clip {
        var c = Clip()
        c.type = type
        c.src = src
        c.start = start
        c.duration = duration
        c.offset = offset
        return c
    }

    private func project(fps: Double = 30, tracks: [Track]) -> Project {
        var p = Project()
        p.width = 1920
        p.height = 1080
        p.fps = fps
        p.tracks = tracks
        return p
    }

    private func track(_ name: String, _ clips: [Clip]) -> Track {
        var t = Track(name: name)
        t.clips = clips
        return t
    }

    // MARK: 書き出しの構造

    func testExportStructure() {
        let p = project(tracks: [
            track("レイヤー1", [
                clip(.video, src: "/media/a.mp4", start: 0, duration: 2, offset: 1),
                clip(.video, src: "/media/b.mp4", start: 2, duration: 3),
            ]),
            track("レイヤー2", [
                clip(.audio, src: "/media/bgm.wav", start: 0, duration: 5),
            ]),
        ])
        let out = FcpXmlExporter.export(project: p, sequenceName: "テスト")
        let xml = out.xml
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n<xmeml version=\"4\">"))
        XCTAssertTrue(xml.contains("<name>テスト</name>"))
        XCTAssertTrue(xml.contains("<timebase>30</timebase>"))
        XCTAssertTrue(xml.contains("<ntsc>FALSE</ntsc>"))
        XCTAssertTrue(xml.contains("<width>1920</width>"))
        XCTAssertTrue(xml.contains("<height>1080</height>"))
        // 配置と使用範囲はフレーム数(30fps: 1 秒 = 30)
        XCTAssertTrue(xml.contains("<start>0</start>"))
        XCTAssertTrue(xml.contains("<end>60</end>"))
        XCTAssertTrue(xml.contains("<in>30</in>"))   // offset 1 秒
        XCTAssertTrue(xml.contains("<out>90</out>"))  // in + 60 フレーム
        XCTAssertTrue(xml.contains("<start>60</start>"))
        XCTAssertTrue(xml.contains("<end>150</end>"))
        // 素材参照は file://localhost の pathurl
        XCTAssertTrue(xml.contains("<pathurl>file://localhost/media/a.mp4</pathurl>"))
        XCTAssertTrue(xml.contains("<pathurl>file://localhost/media/bgm.wav</pathurl>"))
        // シーケンスの長さは最後のクリップの終わり(5 秒 = 150)
        XCTAssertTrue(xml.contains("<duration>150</duration>"))
        XCTAssertEqual(out.report.convertedCounts["video"], 2)
        XCTAssertEqual(out.report.convertedCounts["audio"], 1)
        XCTAssertFalse(out.report.hasLoss)
    }

    func testExportEscapesAndEncodesPaths() {
        let p = project(tracks: [
            track("レイヤー1", [clip(.video, src: "/media/テスト & 1.mp4", start: 0, duration: 1)]),
        ])
        let xml = FcpXmlExporter.export(project: p).xml
        // 日本語と空白と & は pathurl ではパーセントエンコードされる(生の日本語が pathurl に出ない)
        XCTAssertFalse(xml.contains("<pathurl>file://localhost/media/テスト"))
        XCTAssertTrue(xml.contains("<pathurl>file://localhost/media/%E3%83%86%E3%82%B9%E3%83%88")) // テス
        XCTAssertTrue(xml.contains("%20%26%20"))
        // 名前は XML エスケープされる
        XCTAssertTrue(xml.contains("<name>テスト &amp; 1.mp4</name>"))
    }

    func testSameFileIsDefinedOnceAndReferencedAfter() {
        let p = project(tracks: [
            track("レイヤー1", [
                clip(.video, src: "/media/a.mp4", start: 0, duration: 1),
                clip(.video, src: "/media/a.mp4", start: 1, duration: 1, offset: 5),
            ]),
        ])
        let xml = FcpXmlExporter.export(project: p).xml
        XCTAssertEqual(xml.components(separatedBy: "<pathurl>").count - 1, 1, "完全な file 定義は 1 回だけ")
        XCTAssertTrue(xml.contains("<file id=\"file1\"/>"), "2 回目は id 参照だけ")
    }

    // MARK: 往復

    func testRoundTripPreservesCutsMediaAndBasicTransforms() throws {
        var v1 = clip(.video, src: "/media/テスト 1.mp4", start: 0, duration: 2, offset: 0.5)
        v1.x = 0.25; v1.y = 0.75; v1.scale = 1.5; v1.opacity = 0.5; v1.rotation = 15
        v1.srcDuration = 10
        var img = clip(.image, src: "/media/pic.png", start: 2, duration: 1.5)
        img.opacity = 0.8
        var a1 = clip(.audio, src: "/media/voice.wav", start: 0.25, duration: 3)
        a1.volume = 0.5
        var p = project(tracks: [track("レイヤー1", [v1, img]), track("レイヤー2", [a1])])
        p.markers = [Marker(time: 1.0, name: "見どころ")]

        let exported = FcpXmlExporter.export(project: p)
        let imported = try FcpXmlImporter.parse(xml: exported.xml)
        let q = imported.project

        XCTAssertEqual(q.width, 1920)
        XCTAssertEqual(q.height, 1080)
        XCTAssertEqual(q.fps, 30, accuracy: 0.001)
        XCTAssertEqual(q.tracks.count, 2)

        let vClips = q.tracks[0].clips
        XCTAssertEqual(vClips.count, 2)
        let r1 = vClips[0]
        XCTAssertEqual(r1.type, .video)
        XCTAssertEqual(r1.src, "/media/テスト 1.mp4")
        XCTAssertEqual(r1.start, 0, accuracy: 0.001)
        XCTAssertEqual(r1.duration, 2, accuracy: 0.001)
        XCTAssertEqual(r1.offset, 0.5, accuracy: 0.001)
        XCTAssertEqual(r1.srcDuration ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(r1.xOrDefault, 0.25, accuracy: 0.0001)
        XCTAssertEqual(r1.yOrDefault, 0.75, accuracy: 0.0001)
        XCTAssertEqual(r1.scaleOrDefault, 1.5, accuracy: 0.001)
        XCTAssertEqual(r1.opacityOrDefault, 0.5, accuracy: 0.001)
        XCTAssertEqual(r1.rotationOrDefault, 15, accuracy: 0.001)

        let r2 = vClips[1]
        XCTAssertEqual(r2.type, .image)
        XCTAssertEqual(r2.src, "/media/pic.png")
        XCTAssertEqual(r2.start, 2, accuracy: 0.001)
        XCTAssertEqual(r2.duration, 1.5, accuracy: 0.001)
        XCTAssertEqual(r2.opacityOrDefault, 0.8, accuracy: 0.001)

        let aClips = q.tracks[1].clips
        XCTAssertEqual(aClips.count, 1)
        XCTAssertEqual(aClips[0].type, .audio)
        XCTAssertEqual(aClips[0].src, "/media/voice.wav")
        XCTAssertEqual(aClips[0].start, 0.25, accuracy: 0.02) // 0.25 秒は 7.5 フレーム → 8 フレームに丸まる
        XCTAssertEqual(aClips[0].duration, 3, accuracy: 0.001)
        XCTAssertEqual(aClips[0].volumeOrDefault, 0.5, accuracy: 0.001)

        XCTAssertEqual(q.markers.count, 1)
        XCTAssertEqual(q.markers[0].name, "見どころ")
        XCTAssertEqual(q.markers[0].time, 1.0, accuracy: 0.001)
        XCTAssertEqual(Set(q.mediaPool), Set(["/media/テスト 1.mp4", "/media/pic.png", "/media/voice.wav"]))
    }

    func testRoundTripNTSCRate() throws {
        // 29.97fps: timebase 30 + ntsc TRUE で書き、読み戻しても 29.97 に戻る。
        let p = project(fps: 29.97, tracks: [
            track("レイヤー1", [clip(.video, src: "/media/a.mp4", start: 0, duration: 10.01)]),
        ])
        let exported = FcpXmlExporter.export(project: p)
        XCTAssertTrue(exported.xml.contains("<timebase>30</timebase>"))
        XCTAssertTrue(exported.xml.contains("<ntsc>TRUE</ntsc>"))
        XCTAssertTrue(exported.xml.contains("<displayformat>DF</displayformat>"))
        // 10.01 秒 × 30000/1001 = 300 フレーム
        XCTAssertTrue(exported.xml.contains("<end>300</end>"))
        let q = try FcpXmlImporter.parse(xml: exported.xml).project
        XCTAssertEqual(q.fps, 29.97, accuracy: 0.001)
        XCTAssertEqual(q.tracks[0].clips[0].duration, 10.01, accuracy: 0.001)
    }

    func testRoundTripDisabledClip() throws {
        var c = clip(.video, src: "/media/a.mp4", start: 0, duration: 1)
        c.disabled = true
        let p = project(tracks: [track("レイヤー1", [c])])
        let xml = FcpXmlExporter.export(project: p).xml
        XCTAssertTrue(xml.contains("<enabled>FALSE</enabled>"))
        let q = try FcpXmlImporter.parse(xml: xml).project
        XCTAssertEqual(q.tracks[0].clips[0].isDisabled, true)
    }

    // MARK: 落ちる要素はレポートに出る(黙って落とさない)

    func testUnsupportedClipsAndDroppedFeaturesAreReported() {
        var text = clip(.text, src: nil, start: 0, duration: 2)
        text.text = "テロップ"
        var voice = clip(.voice, src: nil, start: 0, duration: 2)
        voice.text = "セリフ"
        var fancy = clip(.video, src: "/media/a.mp4", start: 0, duration: 2)
        fancy.keyframes = ["x": [Keyframe(t: 0, v: 0.2), Keyframe(t: 1, v: 0.8)]]
        fancy.transitionIn = Transition(.fade, duration: 0.5)
        fancy.effects = []
        let p = project(tracks: [track("レイヤー1", [text, voice, fancy])])
        let out = FcpXmlExporter.export(project: p)
        XCTAssertEqual(out.report.unsupported.count, 2)
        XCTAssertTrue(out.report.unsupported.contains { $0.typeName == "text" })
        XCTAssertTrue(out.report.unsupported.contains { $0.typeName == "voice" })
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("キーフレーム") })
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("トランジション") })
        XCTAssertTrue(out.report.hasLoss)
        // 書き出せたのは動画 1 件だけ
        XCTAssertEqual(out.report.convertedCount, 1)
    }

    func testSpeedIsReportedAndExportedAsNormalRange() {
        var c = clip(.video, src: "/media/a.mp4", start: 0, duration: 2, offset: 1)
        c.speed = 2
        let p = project(tracks: [track("レイヤー1", [c])])
        let out = FcpXmlExporter.export(project: p)
        XCTAssertTrue(out.report.droppedFeatures.contains { $0.feature.contains("速度") })
        // out - in は end - start と一致する(等倍の範囲として書く)
        XCTAssertTrue(out.xml.contains("<in>30</in>"))
        XCTAssertTrue(out.xml.contains("<out>90</out>"))
    }

    // MARK: 読み込み(Premiere 風の手書きサンプル)

    func testImportPremiereStyleSample() throws {
        // Premiere の FCP XML 書き出しに倣った形(project > children > sequence、
        // トランジションで挟まれた clipitem は start / end が -1 になる)。
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
          <project>
            <name>Sample</name>
            <children>
              <sequence id="seq">
                <name>Sequence 01</name>
                <duration>243</duration>
                <rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>
                <media>
                  <video>
                    <format>
                      <samplecharacteristics>
                        <width>1280</width>
                        <height>720</height>
                      </samplecharacteristics>
                    </format>
                    <track>
                      <clipitem id="c1">
                        <name>first.mp4</name>
                        <duration>153</duration>
                        <rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>
                        <start>0</start>
                        <end>-1</end>
                        <in>0</in>
                        <out>153</out>
                        <file id="f1">
                          <name>first.mp4</name>
                          <pathurl>file://localhost/media/first.mp4</pathurl>
                          <duration>500</duration>
                        </file>
                        <filter>
                          <effect>
                            <name>Basic Motion</name>
                            <effectid>basic</effectid>
                            <parameter>
                              <parameterid>scale</parameterid>
                              <value>50</value>
                            </parameter>
                            <parameter>
                              <parameterid>center</parameterid>
                              <value><horiz>0.25</horiz><vert>-0.25</vert></value>
                            </parameter>
                          </effect>
                        </filter>
                        <filter>
                          <effect>
                            <name>Opacity</name>
                            <effectid>opacity</effectid>
                            <parameter>
                              <parameterid>opacity</parameterid>
                              <value>60</value>
                            </parameter>
                          </effect>
                        </filter>
                      </clipitem>
                      <transitionitem>
                        <start>123</start>
                        <end>153</end>
                        <effect><name>Cross Dissolve</name></effect>
                      </transitionitem>
                      <clipitem id="c2">
                        <name>second.mp4</name>
                        <duration>120</duration>
                        <rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>
                        <start>-1</start>
                        <end>243</end>
                        <in>30</in>
                        <out>150</out>
                        <file id="f2">
                          <name>second.mp4</name>
                          <pathurl>file://localhost/media/second.mp4</pathurl>
                          <duration>400</duration>
                        </file>
                      </clipitem>
                    </track>
                  </video>
                  <audio>
                    <track>
                      <clipitem id="a1">
                        <name>music.wav</name>
                        <duration>243</duration>
                        <start>0</start>
                        <end>243</end>
                        <in>0</in>
                        <out>243</out>
                        <file id="f3">
                          <name>music.wav</name>
                          <pathurl>file://localhost/media/music.wav</pathurl>
                          <duration>1000</duration>
                        </file>
                      </clipitem>
                    </track>
                  </audio>
                </media>
              </sequence>
            </children>
          </project>
        </xmeml>
        """
        let out = try FcpXmlImporter.parse(xml: xml)
        let q = out.project
        XCTAssertEqual(q.width, 1280)
        XCTAssertEqual(q.height, 720)
        XCTAssertEqual(q.fps, 25, accuracy: 0.001)
        XCTAssertEqual(q.tracks.count, 2)
        let v = q.tracks[0].clips
        XCTAssertEqual(v.count, 2)
        // トランジションを挟んだ -1 の解決: 1 件目は end = トランジションの end(153)、2 件目は start = トランジションの start(123)
        XCTAssertEqual(v[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(v[0].duration, 153.0 / 25.0, accuracy: 0.001)
        XCTAssertEqual(v[0].scaleOrDefault, 0.5, accuracy: 0.001)
        XCTAssertEqual(v[0].xOrDefault, 0.75, accuracy: 0.001)
        XCTAssertEqual(v[0].yOrDefault, 0.25, accuracy: 0.001)
        XCTAssertEqual(v[0].opacityOrDefault, 0.6, accuracy: 0.001)
        XCTAssertEqual(v[0].srcDuration ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(v[1].start, 123.0 / 25.0, accuracy: 0.001)
        XCTAssertEqual(v[1].duration, 120.0 / 25.0, accuracy: 0.001)
        XCTAssertEqual(v[1].offset, 30.0 / 25.0, accuracy: 0.001)
        // トランジションは読み込まずレポートに出る
        XCTAssertTrue(out.report.unsupported.contains { $0.element == "transitionitem" })
        let a = q.tracks[1].clips
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].type, .audio)
        XCTAssertEqual(a[0].src, "/media/music.wav")
    }

    func testImportFileReferenceById() throws {
        // 2 件目以降の clipitem は <file id="..."/> の参照だけでも素材が解決できる。
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
          <sequence>
            <name>S</name>
            <duration>50</duration>
            <rate><timebase>25</timebase><ntsc>FALSE</ntsc></rate>
            <media>
              <video>
                <format><samplecharacteristics><width>640</width><height>360</height></samplecharacteristics></format>
                <track>
                  <clipitem>
                    <name>a.mp4</name>
                    <start>0</start><end>25</end><in>0</in><out>25</out>
                    <file id="f1"><name>a.mp4</name><pathurl>file://localhost/m/a.mp4</pathurl><duration>100</duration></file>
                  </clipitem>
                  <clipitem>
                    <name>a.mp4</name>
                    <start>25</start><end>50</end><in>25</in><out>50</out>
                    <file id="f1"/>
                  </clipitem>
                </track>
              </video>
            </media>
          </sequence>
        </xmeml>
        """
        let q = try FcpXmlImporter.parse(xml: xml).project
        XCTAssertEqual(q.tracks[0].clips.count, 2)
        XCTAssertEqual(q.tracks[0].clips[1].src, "/m/a.mp4")
        XCTAssertEqual(q.tracks[0].clips[1].offset, 1.0, accuracy: 0.001)
        XCTAssertEqual(q.tracks[0].clips[1].srcDuration ?? 0, 4.0, accuracy: 0.001)
    }

    func testImportRejectsNonXmeml() {
        // FCPXML(現在の Final Cut Pro の形式)は別形式なので、はっきり断る。
        let fcpxml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><fcpxml version=\"1.10\"><resources/></fcpxml>"
        XCTAssertThrowsError(try FcpXmlImporter.parse(xml: fcpxml)) { error in
            XCTAssertTrue(error is FcpXmlImporter.ImportError)
        }
        XCTAssertThrowsError(try FcpXmlImporter.parse(xml: "これは XML ではありません"))
    }

    // MARK: レート対応

    func testRateMapping() {
        XCTAssertEqual(XmemlRate.from(fps: 30).timebase, 30)
        XCTAssertEqual(XmemlRate.from(fps: 30).ntsc, false)
        XCTAssertEqual(XmemlRate.from(fps: 29.97).timebase, 30)
        XCTAssertEqual(XmemlRate.from(fps: 29.97).ntsc, true)
        XCTAssertEqual(XmemlRate.from(fps: 23.976).timebase, 24)
        XCTAssertEqual(XmemlRate.from(fps: 23.976).ntsc, true)
        XCTAssertEqual(XmemlRate.from(fps: 59.94).timebase, 60)
        XCTAssertEqual(XmemlRate.from(fps: 59.94).ntsc, true)
        XCTAssertEqual(XmemlRate.fps(timebase: 30, ntsc: true), 29.97, accuracy: 0.0001)
        XCTAssertEqual(XmemlRate.fps(timebase: 25, ntsc: false), 25, accuracy: 0.0001)
        XCTAssertTrue(XmemlRate.from(fps: 12.5).isApproximate)
        XCTAssertFalse(XmemlRate.from(fps: 60).isApproximate)
    }

    func testPathURLCoding() {
        XCTAssertEqual(XmemlText.pathURL(for: "/a b/テスト.mp4"), "file://localhost/a%20b/%E3%83%86%E3%82%B9%E3%83%88.mp4")
        XCTAssertEqual(XmemlText.path(fromPathURL: "file://localhost/a%20b/%E3%83%86%E3%82%B9%E3%83%88.mp4"), "/a b/テスト.mp4")
        XCTAssertEqual(XmemlText.path(fromPathURL: "file:///a/b.mp4"), "/a/b.mp4")
        XCTAssertEqual(XmemlText.path(fromPathURL: "relative/c.mp4"), "relative/c.mp4")
    }
}
