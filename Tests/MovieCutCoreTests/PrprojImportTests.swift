import XCTest
@testable import MovieCutCore

/// Premiere Pro プロジェクト(.prproj)読み込みの検証。
/// フィクスチャは、公開資料(prproj-parser の形式ノート等)で確認した実構造
/// (PremiereData 直下のオブジェクトグラフ、tick = 1/254016000000 秒、
/// Sequence → TrackGroup → ClipTrack → ClipTrackItem → SubClip → VideoClip →
/// MediaSource → Media の参照連鎖)に沿って自作したもの。
/// 実 Premiere Pro のファイルでの読み込みは未検証(docs/Prproj読み込み.md)。
final class PrprojImportTests: XCTestCase {

    // MARK: フィクスチャ A(基本形: 変換・音量・速度・マーカー・トランジション・ネスト)

    private let fixtureA = #"""
    <?xml version="1.0" encoding="UTF-8" ?>
    <PremiereData Version="3">
        <Project ObjectRef="1"/>
        <Project ObjectID="1" ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="42">
            <RootProjectItem ObjectURef="root-1"/>
        </Project>
        <Sequence ObjectUID="seq-1" Version="11">
            <TrackGroups Version="1">
                <TrackGroup Version="1" Index="0">
                    <First>228cda18-3625-4d2d-951e-348879e4ed93</First>
                    <Second ObjectRef="10"/>
                </TrackGroup>
                <TrackGroup Version="1" Index="1">
                    <First>80b8e3d5-6dca-4195-aefb-cb5f407ab009</First>
                    <Second ObjectRef="11"/>
                </TrackGroup>
                <TrackGroup Version="1" Index="2">
                    <First>d8143ffe-eec4-4d2a-a909-d5f7bf094dc5</First>
                    <Second ObjectRef="12"/>
                </TrackGroup>
            </TrackGroups>
            <Name>メインシーケンス</Name>
            <MarkerOwner>
                <Markers>
                    <Marker Index="0"><Second ObjectRef="900"/></Marker>
                </Markers>
            </MarkerOwner>
        </Sequence>
        <Marker ObjectID="900" Version="3">
            <DVAMarker>{"DVAMarker":{"mMarkerID":"abc","mStartTime":{"ticks":508032000000},"mDuration":{"ticks":0},"mName":"見どころ","mType":"Comment"}}</DVAMarker>
        </Marker>
        <VideoTrackGroup ObjectID="10" Version="13">
            <TrackGroup Version="1">
                <Tracks Version="1">
                    <Track Index="0" ObjectURef="track-v1"/>
                    <Track Index="1" ObjectURef="track-v2"/>
                </Tracks>
                <FrameRate>10160640000</FrameRate>
            </TrackGroup>
            <FrameRect>0,0,1920,1080</FrameRect>
        </VideoTrackGroup>
        <AudioTrackGroup ObjectID="11" Version="6">
            <TrackGroup Version="1">
                <Tracks Version="1">
                    <Track Index="0" ObjectURef="track-a1"/>
                </Tracks>
                <FrameRate>5292000</FrameRate>
            </TrackGroup>
        </AudioTrackGroup>
        <DataTrackGroup ObjectID="12" Version="1">
            <TrackGroup Version="1">
                <FrameRate>10160640000</FrameRate>
            </TrackGroup>
        </DataTrackGroup>
        <VideoClipTrack ObjectUID="track-v1" Version="1">
            <ClipTrack Version="2">
                <Track Version="3">
                    <IsLocked>false</IsLocked>
                    <IsMuted>false</IsMuted>
                </Track>
                <ClipItems Version="3">
                    <TrackItems Version="1">
                        <TrackItem Index="0" ObjectRef="100"/>
                        <TrackItem Index="1" ObjectRef="101"/>
                    </TrackItems>
                </ClipItems>
                <TransitionItems Version="3">
                    <TrackItems Version="1">
                        <TrackItem Index="0" ObjectRef="300"/>
                    </TrackItems>
                </TransitionItems>
            </ClipTrack>
        </VideoClipTrack>
        <VideoClipTrack ObjectUID="track-v2" Version="1">
            <ClipTrack Version="2">
                <Track Version="3">
                    <IsLocked>true</IsLocked>
                    <IsMuted>false</IsMuted>
                </Track>
                <ClipItems Version="3">
                    <TrackItems Version="1">
                        <TrackItem Index="0" ObjectRef="102"/>
                        <TrackItem Index="1" ObjectRef="103"/>
                    </TrackItems>
                </ClipItems>
            </ClipTrack>
        </VideoClipTrack>
        <AudioClipTrack ObjectUID="track-a1" Version="1">
            <ClipTrack Version="2">
                <Track Version="3">
                    <IsLocked>false</IsLocked>
                    <IsMuted>true</IsMuted>
                </Track>
                <ClipItems Version="3">
                    <TrackItems Version="1">
                        <TrackItem Index="0" ObjectRef="200"/>
                    </TrackItems>
                </ClipItems>
            </ClipTrack>
        </AudioClipTrack>
        <VideoTransitionTrackItem ObjectID="300" Version="5">
            <TransitionTrackItem Version="3">
                <TrackItem Version="3">
                    <Start>0</Start>
                    <End>127008000000</End>
                </TrackItem>
                <DisplayName>Cross Dissolve</DisplayName>
                <MatchName>AE.ADBE Cross Dissolve New</MatchName>
            </TransitionTrackItem>
        </VideoTransitionTrackItem>
        <VideoClipTrackItem ObjectID="100" Version="6">
            <ClipTrackItem Version="8">
                <ComponentOwner Version="1">
                    <Components ObjectRef="500"/>
                </ComponentOwner>
                <TrackItem Version="3">
                    <Start>0</Start>
                    <End>1270080000000</End>
                </TrackItem>
                <SubClip ObjectRef="400"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="101" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>1270080000000</Start>
                    <End>1778112000000</End>
                </TrackItem>
                <SubClip ObjectRef="401"/>
                <IsMuted>true</IsMuted>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="102" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>0</Start>
                    <End>762048000000</End>
                </TrackItem>
                <SubClip ObjectRef="402"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="103" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>762048000000</Start>
                    <End>1270080000000</End>
                </TrackItem>
                <SubClip ObjectRef="403"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <AudioClipTrackItem ObjectID="200" Version="6">
            <ClipTrackItem Version="8">
                <ComponentOwner Version="1">
                    <Components ObjectRef="501"/>
                </ComponentOwner>
                <TrackItem Version="3">
                    <Start>0</Start>
                    <End>1270080000000</End>
                </TrackItem>
                <SubClip ObjectRef="404"/>
            </ClipTrackItem>
        </AudioClipTrackItem>
        <SubClip ObjectID="400" Version="5">
            <Clip ObjectRef="600"/>
            <MasterClip ObjectURef="mc-1"/>
            <Name>clipA.mp4</Name>
        </SubClip>
        <SubClip ObjectID="401" Version="5">
            <Clip ObjectRef="601"/>
            <MasterClip ObjectURef="mc-1"/>
            <Name>clipA.mp4</Name>
        </SubClip>
        <SubClip ObjectID="402" Version="5">
            <Clip ObjectRef="602"/>
            <MasterClip ObjectURef="mc-2"/>
            <Name>photo.jpg</Name>
        </SubClip>
        <SubClip ObjectID="403" Version="5">
            <Clip ObjectRef="603"/>
            <MasterClip ObjectURef="mc-3"/>
            <Name>サブシーケンス</Name>
        </SubClip>
        <SubClip ObjectID="404" Version="5">
            <Clip ObjectRef="604"/>
            <MasterClip ObjectURef="mc-4"/>
            <Name>bgm.wav</Name>
        </SubClip>
        <MasterClip ObjectUID="mc-1" Version="11">
            <Clips Version="1">
                <Clip Index="0" ObjectRef="600"/>
            </Clips>
            <Name>clipA.mp4</Name>
        </MasterClip>
        <MasterClip ObjectUID="mc-2" Version="11">
            <Clips Version="1">
                <Clip Index="0" ObjectRef="602"/>
            </Clips>
            <Name>photo.jpg</Name>
        </MasterClip>
        <MasterClip ObjectUID="mc-3" Version="11">
            <Clips Version="1">
                <Clip Index="0" ObjectRef="603"/>
            </Clips>
            <Name>サブシーケンス</Name>
        </MasterClip>
        <MasterClip ObjectUID="mc-4" Version="11">
            <Clips Version="1">
                <Clip Index="0" ObjectRef="604"/>
            </Clips>
            <Name>bgm.wav</Name>
        </MasterClip>
        <VideoClip ObjectID="600" Version="11">
            <Clip Version="18">
                <Source ObjectRef="700"/>
                <InPoint>914965632000000</InPoint>
                <OutPoint>916235712000000</OutPoint>
            </Clip>
        </VideoClip>
        <VideoClip ObjectID="601" Version="11">
            <Clip Version="18">
                <Source ObjectRef="700"/>
                <PlaybackSpeed>2</PlaybackSpeed>
                <InPoint>916997760000000</InPoint>
                <OutPoint>918013824000000</OutPoint>
            </Clip>
        </VideoClip>
        <VideoClip ObjectID="602" Version="11">
            <Clip Version="18">
                <Source ObjectRef="701"/>
                <InPoint>123456789000</InPoint>
                <OutPoint>885504789000</OutPoint>
            </Clip>
        </VideoClip>
        <VideoClip ObjectID="603" Version="11">
            <Clip Version="18">
                <Source ObjectRef="702"/>
                <InPoint>0</InPoint>
                <OutPoint>508032000000</OutPoint>
            </Clip>
        </VideoClip>
        <AudioClip ObjectID="604" Version="11">
            <Clip Version="18">
                <Source ObjectRef="703"/>
                <InPoint>0</InPoint>
                <OutPoint>1270080000000</OutPoint>
            </Clip>
        </AudioClip>
        <VideoMediaSource ObjectID="700" Version="2">
            <MediaSource Version="4">
                <Media ObjectURef="media-1"/>
            </MediaSource>
            <OriginalDuration>15240960000000</OriginalDuration>
        </VideoMediaSource>
        <VideoMediaSource ObjectID="701" Version="2">
            <MediaSource Version="4">
                <Media ObjectURef="media-2"/>
            </MediaSource>
        </VideoMediaSource>
        <VideoSequenceSource ObjectID="702" Version="2">
            <SequenceSource Version="4">
                <Sequence ObjectURef="seq-2"/>
            </SequenceSource>
        </VideoSequenceSource>
        <AudioMediaSource ObjectID="703" Version="2">
            <MediaSource Version="4">
                <Media ObjectURef="media-3"/>
            </MediaSource>
            <OriginalDuration>15240960000000</OriginalDuration>
        </AudioMediaSource>
        <Media ObjectUID="media-1" Version="28">
            <VideoStream ObjectRef="800"/>
            <FilePath>/media/clipA.mp4</FilePath>
            <Title>clipA.mp4</Title>
            <Start>914457600000000</Start>
        </Media>
        <Media ObjectUID="media-2" Version="28">
            <VideoStream ObjectRef="801"/>
            <FilePath>C:\Media\photo.jpg</FilePath>
            <Title>photo.jpg</Title>
        </Media>
        <Media ObjectUID="media-3" Version="28">
            <AudioStream ObjectRef="802"/>
            <FilePath>/media/bgm.wav</FilePath>
            <Title>bgm.wav</Title>
        </Media>
        <VideoStream ObjectID="800" Version="19">
            <FrameRate>10160640000</FrameRate>
            <Duration>15240960000000</Duration>
            <FrameRect>0,0,1920,1080</FrameRect>
        </VideoStream>
        <VideoStream ObjectID="801" Version="19">
            <FrameRate>10160640000</FrameRate>
            <IsStill>true</IsStill>
        </VideoStream>
        <AudioStream ObjectID="802" Version="19">
            <FrameRate>5292000</FrameRate>
            <Duration>15240960000000</Duration>
        </AudioStream>
        <VideoComponentChain ObjectID="500" Version="3">
            <ComponentChain Version="3">
                <Components Version="1">
                    <Component Index="0" ObjectRef="510"/>
                    <Component Index="1" ObjectRef="511"/>
                    <Component Index="2" ObjectRef="512"/>
                </Components>
            </ComponentChain>
        </VideoComponentChain>
        <AudioComponentChain ObjectID="501" Version="3">
            <ComponentChain Version="3">
                <Components Version="1">
                    <Component Index="0" ObjectRef="513"/>
                </Components>
            </ComponentChain>
        </AudioComponentChain>
        <VideoFilterComponent ObjectID="510" Version="9">
            <Component Version="6">
                <Params Version="1">
                    <Param Index="0" ObjectRef="520"/>
                    <Param Index="1" ObjectRef="521"/>
                    <Param Index="2" ObjectRef="522"/>
                    <Param Index="3" ObjectRef="523"/>
                    <Param Index="4" ObjectRef="524"/>
                    <Param Index="5" ObjectRef="525"/>
                </Params>
                <DisplayName>Motion</DisplayName>
                <Intrinsic>true</Intrinsic>
            </Component>
            <MatchName>AE.ADBE Motion</MatchName>
        </VideoFilterComponent>
        <VideoFilterComponent ObjectID="511" Version="9">
            <Component Version="6">
                <Params Version="1">
                    <Param Index="0" ObjectRef="530"/>
                </Params>
                <DisplayName>Opacity</DisplayName>
                <Intrinsic>true</Intrinsic>
            </Component>
            <MatchName>AE.ADBE Opacity</MatchName>
        </VideoFilterComponent>
        <VideoFilterComponent ObjectID="512" Version="9">
            <Component Version="6">
                <Params Version="1">
                </Params>
                <DisplayName>Lumetri Color</DisplayName>
            </Component>
            <MatchName>AE.ADBE Lumetri</MatchName>
        </VideoFilterComponent>
        <AudioFilterComponent ObjectID="513" Version="9">
            <AudioComponent Version="1">
                <Component Version="6">
                    <Params Version="1">
                        <Param Index="0" ObjectRef="531"/>
                    </Params>
                    <DisplayName>Volume</DisplayName>
                    <Intrinsic>true</Intrinsic>
                </Component>
            </AudioComponent>
            <MatchName>Internal Volume</MatchName>
        </AudioFilterComponent>
        <PointComponentParam ObjectID="520" Version="3">
            <ParameterID>1</ParameterID>
            <Name>Position</Name>
            <StartKeyframe>-91445760000000000,0.25:0.75,0,0,0,0,0,0,0,0,0,0,0,0</StartKeyframe>
        </PointComponentParam>
        <VideoComponentParam ObjectID="521" Version="9">
            <ParameterID>2</ParameterID>
            <Name>Scale</Name>
            <StartKeyframe>-91445760000000000,150.,0,0,0,0,0,0</StartKeyframe>
        </VideoComponentParam>
        <VideoComponentParam ObjectID="522" Version="9">
            <ParameterID>3</ParameterID>
            <Name>Scale Width</Name>
            <StartKeyframe>-91445760000000000,150.,0,0,0,0,0,0</StartKeyframe>
        </VideoComponentParam>
        <VideoComponentParam ObjectID="523" Version="9">
            <ParameterID>4</ParameterID>
            <Name>Uniform Scale</Name>
            <StartKeyframe>-91445760000000000,true,0,0,0,0,0,0</StartKeyframe>
        </VideoComponentParam>
        <VideoComponentParam ObjectID="524" Version="9">
            <ParameterID>5</ParameterID>
            <Name>Rotation</Name>
            <StartKeyframe>-91445760000000000,30.,0,0,0,0,0,0</StartKeyframe>
        </VideoComponentParam>
        <PointComponentParam ObjectID="525" Version="3">
            <ParameterID>6</ParameterID>
            <Name>Anchor Point</Name>
            <StartKeyframe>-91445760000000000,0.5:0.5,0,0,0,0,0,0,0,0,0,0,0,0</StartKeyframe>
        </PointComponentParam>
        <VideoComponentParam ObjectID="530" Version="9">
            <ParameterID>1</ParameterID>
            <Name>Opacity</Name>
            <StartKeyframe>-91445760000000000,50.,0,0,0,0,0,0</StartKeyframe>
        </VideoComponentParam>
        <AudioComponentParam ObjectID="531" Version="9">
            <Name>Level</Name>
            <StartKeyframe>-91445760000000000,0.355655878882,0,0,0,0,0,0</StartKeyframe>
        </AudioComponentParam>
        <Sequence ObjectUID="seq-2" Version="11">
            <Name>サブシーケンス</Name>
        </Sequence>
    </PremiereData>
    """#

    // MARK: 基本形の検証

    func testBasicImportPlacementMediaAndTransform() throws {
        let out = try PrprojImporter.parse(data: Data(fixtureA.utf8))
        let p = out.project
        XCTAssertEqual(p.fps, 25, accuracy: 0.001)
        XCTAssertEqual(p.width, 1920)
        XCTAssertEqual(p.height, 1080)
        XCTAssertEqual(p.tracks.count, 3)
        XCTAssertEqual(p.tracks.map { $0.name }, ["V1", "V2", "A1"])
        XCTAssertEqual(p.tracks[1].isLocked, true, "トラックのロックが移る")
        XCTAssertEqual(p.tracks[2].isMuted, true, "音声トラックのミュートが移る")

        // V1 の 1 つ目: 配置・使用範囲(開始タイムコード 3600 秒を差し引く)・基本変換
        let v1 = p.tracks[0].clips
        XCTAssertEqual(v1.count, 2)
        let c0 = v1[0]
        XCTAssertEqual(c0.type, .video)
        XCTAssertEqual(c0.src, "/media/clipA.mp4")
        XCTAssertEqual(c0.start, 0, accuracy: 0.0001)
        XCTAssertEqual(c0.duration, 5, accuracy: 0.0001)
        XCTAssertEqual(c0.offset, 2, accuracy: 0.0001)
        XCTAssertEqual(c0.srcDuration ?? -1, 60, accuracy: 0.0001)
        XCTAssertEqual(c0.xOrDefault, 0.25, accuracy: 0.0001)
        XCTAssertEqual(c0.yOrDefault, 0.75, accuracy: 0.0001)
        XCTAssertEqual(c0.scaleOrDefault, 1.5, accuracy: 0.0001)
        XCTAssertEqual(c0.rotationOrDefault, 30, accuracy: 0.0001)
        XCTAssertEqual(c0.opacityOrDefault, 0.5, accuracy: 0.0001)

        // V1 の 2 つ目: 同じ素材の別インスタンス。2 倍速と無効化が移る
        let c1 = v1[1]
        XCTAssertEqual(c1.start, 5, accuracy: 0.0001)
        XCTAssertEqual(c1.duration, 2, accuracy: 0.0001)
        XCTAssertEqual(c1.offset, 10, accuracy: 0.0001)
        XCTAssertEqual(c1.speed ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(c1.isDisabled, true)

        // V2: 静止画(Windows パスはスラッシュへ)。ネストは落ちてレポートへ
        let v2 = p.tracks[1].clips
        XCTAssertEqual(v2.count, 1)
        XCTAssertEqual(v2[0].type, .image)
        XCTAssertEqual(v2[0].src, "C:/Media/photo.jpg")
        XCTAssertEqual(v2[0].duration, 3, accuracy: 0.0001)
        XCTAssertEqual(v2[0].offset, 0, accuracy: 0.0001)

        // A1: 音量(Level 0.3556 ≒ +6dB ≒ 2 倍)
        let a1 = p.tracks[2].clips
        XCTAssertEqual(a1.count, 1)
        XCTAssertEqual(a1[0].type, .audio)
        XCTAssertEqual(a1[0].src, "/media/bgm.wav")
        XCTAssertEqual(a1[0].duration, 5, accuracy: 0.0001)
        XCTAssertEqual(a1[0].volumeOrDefault, 2.0, accuracy: 0.01)

        // マーカーと素材プール
        XCTAssertEqual(p.markers.count, 1)
        XCTAssertEqual(p.markers[0].time, 2, accuracy: 0.0001)
        XCTAssertEqual(p.markers[0].name, "見どころ")
        XCTAssertEqual(Set(p.mediaPool), Set(["/media/clipA.mp4", "C:/Media/photo.jpg", "/media/bgm.wav"]))

        // レポート: 変換数と、落ちた要素が理由つきで残ること
        XCTAssertEqual(out.report.convertedCounts["video"], 2)
        XCTAssertEqual(out.report.convertedCounts["image"], 1)
        XCTAssertEqual(out.report.convertedCounts["audio"], 1)
        XCTAssertTrue(out.report.hasLoss)
        let unsupportedText = out.report.unsupported.map { "\($0.element)|\($0.label)|\($0.reason)" }.joined(separator: "\n")
        XCTAssertTrue(unsupportedText.contains("Lumetri"), "未対応エフェクトがレポートに残る: \(unsupportedText)")
        XCTAssertTrue(unsupportedText.contains("Cross Dissolve"), "トランジションがレポートに残る: \(unsupportedText)")
        XCTAssertTrue(unsupportedText.contains("SequenceSource"), "ネストがレポートに残る: \(unsupportedText)")
        XCTAssertTrue(unsupportedText.contains("サブシーケンス"), "他のシーケンスがレポートに残る: \(unsupportedText)")
        XCTAssertTrue(out.report.notes.contains { $0.contains("メインシーケンス") })
        XCTAssertFalse(out.report.summaryLines.isEmpty)
    }

    // MARK: フィクスチャ B(複数シーケンス・欠けた参照・生成素材・キーフレーム・Start 省略)

    private let fixtureB = #"""
    <?xml version="1.0" encoding="UTF-8" ?>
    <PremiereData Version="3">
        <Project ObjectID="1" ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="45">
        </Project>
        <Sequence ObjectUID="seq-b1" Version="11">
            <Name>空シーケンス</Name>
        </Sequence>
        <Sequence ObjectUID="seq-b2" Version="11">
            <TrackGroups Version="1">
                <TrackGroup Version="1" Index="0">
                    <Second ObjectRef="20"/>
                </TrackGroup>
            </TrackGroups>
            <Name>本編</Name>
        </Sequence>
        <VideoTrackGroup ObjectID="20" Version="13">
            <TrackGroup Version="1">
                <Tracks Version="1">
                    <Track Index="0" ObjectURef="track-b1"/>
                </Tracks>
                <FrameRate>8475667200</FrameRate>
            </TrackGroup>
            <FrameRect>0,0,1280,720</FrameRect>
        </VideoTrackGroup>
        <VideoClipTrack ObjectUID="track-b1" Version="1">
            <ClipTrack Version="2">
                <ClipItems Version="3">
                    <TrackItems Version="1">
                        <TrackItem Index="0" ObjectRef="210"/>
                        <TrackItem Index="1" ObjectRef="211"/>
                        <TrackItem Index="2" ObjectRef="212"/>
                        <TrackItem Index="3" ObjectRef="213"/>
                    </TrackItems>
                </ClipItems>
            </ClipTrack>
        </VideoClipTrack>
        <VideoClipTrackItem ObjectID="210" Version="6">
            <ClipTrackItem Version="8">
                <ComponentOwner Version="1">
                    <Components ObjectRef="550"/>
                </ComponentOwner>
                <TrackItem Version="3">
                    <End>508032000000</End>
                </TrackItem>
                <SubClip ObjectRef="220"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="211" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>508032000000</Start>
                </TrackItem>
                <SubClip ObjectRef="220"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="212" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>508032000000</Start>
                    <End>1016064000000</End>
                </TrackItem>
                <SubClip ObjectRef="221"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <VideoClipTrackItem ObjectID="213" Version="6">
            <ClipTrackItem Version="8">
                <TrackItem Version="3">
                    <Start>1016064000000</Start>
                    <End>1524096000000</End>
                </TrackItem>
                <SubClip ObjectRef="222"/>
            </ClipTrackItem>
        </VideoClipTrackItem>
        <SubClip ObjectID="220" Version="5">
            <Clip ObjectRef="230"/>
            <MasterClip ObjectURef="mc-b1"/>
            <Name>b.mp4</Name>
        </SubClip>
        <SubClip ObjectID="221" Version="5">
            <Clip ObjectRef="231"/>
            <MasterClip ObjectURef="mc-b2"/>
            <Name>Black Video</Name>
        </SubClip>
        <SubClip ObjectID="222" Version="5">
            <Clip ObjectRef="9998"/>
            <MasterClip ObjectURef="mc-missing"/>
            <Name>行方不明.mp4</Name>
        </SubClip>
        <MasterClip ObjectUID="mc-b1" Version="11">
            <Name>b.mp4</Name>
        </MasterClip>
        <MasterClip ObjectUID="mc-b2" Version="11">
            <Name>Black Video</Name>
        </MasterClip>
        <VideoClip ObjectID="230" Version="11">
            <Clip Version="18">
                <Source ObjectRef="240"/>
                <InPoint>0</InPoint>
                <OutPoint>508032000000</OutPoint>
            </Clip>
        </VideoClip>
        <VideoClip ObjectID="231" Version="11">
            <Clip Version="18">
                <Source ObjectRef="241"/>
                <InPoint>0</InPoint>
                <OutPoint>508032000000</OutPoint>
            </Clip>
        </VideoClip>
        <VideoMediaSource ObjectID="240" Version="2">
            <MediaSource Version="4">
                <Media ObjectURef="media-b1"/>
            </MediaSource>
        </VideoMediaSource>
        <VideoMediaSource ObjectID="241" Version="2">
            <MediaSource Version="4">
                <Media ObjectURef="media-b2"/>
            </MediaSource>
        </VideoMediaSource>
        <Media ObjectUID="media-b1" Version="28">
            <FilePath>/media/b.mp4</FilePath>
            <Title>b.mp4</Title>
        </Media>
        <Media ObjectUID="media-b2" Version="28">
            <FilePath>1112293707</FilePath>
            <Title>Black Video</Title>
            <Infinite>true</Infinite>
        </Media>
        <VideoComponentChain ObjectID="550" Version="3">
            <ComponentChain Version="3">
                <Components Version="1">
                    <Component Index="0" ObjectRef="560"/>
                </Components>
            </ComponentChain>
        </VideoComponentChain>
        <VideoFilterComponent ObjectID="560" Version="9">
            <Component Version="6">
                <Params Version="1">
                    <Param Index="0" ObjectRef="570"/>
                </Params>
                <DisplayName>Motion</DisplayName>
                <Intrinsic>true</Intrinsic>
            </Component>
            <MatchName>AE.ADBE Motion</MatchName>
        </VideoFilterComponent>
        <VideoComponentParam ObjectID="570" Version="9">
            <ParameterID>2</ParameterID>
            <Name>Scale</Name>
            <IsTimeVarying>true</IsTimeVarying>
            <StartKeyframe>-91445760000000000,100.,0,0,0,0,0,0</StartKeyframe>
            <Keyframes>0,100.,0,0,0,0,0,0;508032000000,200.,0,0,0,0,0,0</Keyframes>
        </VideoComponentParam>
    </PremiereData>
    """#

    func testMultipleSequencesMissingRefsAndGenerator() throws {
        let out = try PrprojImporter.parse(data: Data(fixtureB.utf8))
        let p = out.project
        // クリップのある「本編」が主シーケンスになる(29.97fps / 1280×720)
        XCTAssertEqual(p.fps, 29.97, accuracy: 0.001)
        XCTAssertEqual(p.width, 1280)
        XCTAssertEqual(p.height, 720)
        XCTAssertTrue(out.report.notes.contains { $0.contains("本編") })
        XCTAssertTrue(out.report.unsupported.contains { $0.element == "Sequence" && $0.label == "空シーケンス" })

        XCTAssertEqual(p.tracks.count, 1)
        let clips = p.tracks[0].clips
        // 210(Start 省略 = 0)と 213(参照が欠けたクリップ)だけが残る
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(clips[0].duration, 2, accuracy: 0.0001)
        XCTAssertEqual(clips[0].src, "/media/b.mp4")
        XCTAssertNil(clips[0].scale, "キーフレーム付きスケールは静止値 100% = 既定なので書かれない")
        XCTAssertTrue(out.report.notes.contains { $0.contains("キーフレーム") }, "キーフレームは静止値で読んだ旨が残る")
        XCTAssertNil(clips[1].src, "参照が欠けたクリップは参照なしで残る")
        XCTAssertEqual(clips[1].start, 4, accuracy: 0.0001)

        // End が無いクリップと生成素材は、理由つきでレポートへ
        XCTAssertTrue(out.report.unsupported.contains { $0.reason.contains("配置(End)") })
        XCTAssertTrue(out.report.unsupported.contains { $0.label == "Black Video" && $0.reason.contains("生成素材") })
    }

    // MARK: ファイル経由(gzip / 素の XML)と壊れたファイル

    func testFixtureFilesGzipAndPlain() throws {
        let gzURL = try XCTUnwrap(Bundle.module.url(forResource: "prproj-basic", withExtension: "prproj", subdirectory: "Fixtures"))
        let plainURL = try XCTUnwrap(Bundle.module.url(forResource: "prproj-plain", withExtension: "prproj", subdirectory: "Fixtures"))
        for url in [gzURL, plainURL] {
            let out = try PrprojImporter.read(from: url)
            XCTAssertEqual(out.project.fps, 25, accuracy: 0.001)
            XCTAssertEqual(out.project.tracks.count, 1)
            XCTAssertEqual(out.project.tracks[0].clips.count, 1)
            XCTAssertEqual(out.project.tracks[0].clips[0].src, "/media/tiny.mp4")
            XCTAssertEqual(out.project.tracks[0].clips[0].duration, 2, accuracy: 0.0001)
        }
        // gzip の中身は素の XML と一致する
        let gzData = try Data(contentsOf: gzURL)
        let plainData = try Data(contentsOf: plainURL)
        XCTAssertEqual(try PrprojImporter.gunzip(gzData), plainData)
    }

    func testBrokenFilesThrowExplicitErrors() {
        // 空
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data())) {
            XCTAssertTrue($0 is PrprojImporter.ImportError)
        }
        // XML として壊れている
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data("<PremiereData><Sequence>".utf8))) {
            guard case PrprojImporter.ImportError.malformedXML = $0 else { return XCTFail("malformedXML のはず: \($0)") }
        }
        // PremiereData ではない XML(FCP XML と取り違えた場合)
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data("<xmeml version=\"4\"></xmeml>".utf8))) {
            guard case PrprojImporter.ImportError.notPrproj = $0 else { return XCTFail("notPrproj のはず: \($0)") }
        }
        // シーケンスが無い
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data("<PremiereData Version=\"3\"></PremiereData>".utf8))) {
            guard case PrprojImporter.ImportError.noSequence = $0 else { return XCTFail("noSequence のはず: \($0)") }
        }
        // gzip が途中で切れている
        let gzURL = Bundle.module.url(forResource: "prproj-basic", withExtension: "prproj", subdirectory: "Fixtures")!
        let full = try! Data(contentsOf: gzURL)
        let truncated = full.prefix(full.count / 2)
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data(truncated))) {
            guard case PrprojImporter.ImportError.gzipFailed = $0 else { return XCTFail("gzipFailed のはず: \($0)") }
        }
        // gzip の中身が壊れている(CRC 不一致になる)
        var corrupted = full
        corrupted[corrupted.count - 12] ^= 0xFF
        XCTAssertThrowsError(try PrprojImporter.parse(data: Data(corrupted)))
    }

    func testCrc32KnownValue() {
        // CRC32("123456789") = 0xCBF43926(標準の検査値)
        XCTAssertEqual(PrprojImporter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}
