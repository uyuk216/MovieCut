# Whisper 文字起こし

Movie Cut は、音声から字幕を作る第 2 のエンジンとして [whisper.cpp](https://github.com/ggerganov/whisper.cpp)(OpenAI Whisper の C/C++ 実装)を使えます。Apple の音声認識より日本語の精度が高いことが期待できます。既定は従来どおり Apple の音声認識で、Whisper は使いたいときだけ選びます。

**モデルはアプリに同梱していません。** whisper.cpp 本体もモデルも、初回利用時に利用者が自分で配置します(下記)。Movie Cut は検証した外部実行ファイルを、シェルを通さず引数配列で実行するだけです。

> **未確認**: この文書を書いた時点では、実エンジン(本物の `whisper-cli`)での動作確認は未実施です。テストは、偽の実行ファイル(固定の JSON を書くスクリプト)で配線・引数・失敗・キャンセルを確かめた範囲です。実際の認識結果・速度・精度は未確認です。

## 1. whisper.cpp を入れる

次のどちらかです。

- **Homebrew**: `brew install whisper-cpp`
  - 実行ファイル `whisper-cli` が `/opt/homebrew/bin`(Intel Mac は `/usr/local/bin`)に入ります。Movie Cut はここも自動で探します。
- **公式リリースのバイナリ**: <https://github.com/ggerganov/whisper.cpp> の Releases からビルド済みを取得(または自分でビルド)し、実行ファイルを後述の配置先に置きます。

実行ファイル名は `whisper-cli` です。旧名の `whisper-cpp` / `main` でも使えます(配置先に置く場合)。

## 2. モデルを入れる

<https://huggingface.co/ggerganov/whisper.cpp> から `ggml-base.bin` などをダウンロードします。

| モデル | ファイル名 | サイズの目安 |
| --- | --- | --- |
| tiny | `ggml-tiny.bin` | 75 MB |
| base | `ggml-base.bin` | 142 MB |
| small | `ggml-small.bin` | 466 MB |
| medium | `ggml-medium.bin` | 1.5 GB |

**日本語は base 以上をおすすめします。** 大きいほど精度は上がりますが、時間とメモリを使います。

## 3. 置き場所

次のどちらかです。

- **配置先フォルダに置く**: `~/Library/Application Support/MovieCut/Whisper/` に、実行ファイルとモデル(`ggml-*.bin`)を入れます(配布版は `Movie Cut (Public)` の下の `Whisper/`)。モデルが複数あるときは、大きいものを優先します(large-v3、large-v3-turbo、medium、small、base、tiny の順)。
- **設定画面で選ぶ**: 「設定」シートの「Whisper(文字起こし)」欄で「実行ファイルを選ぶ…」「モデルを選ぶ…」を押して選びます。「選択を解除」で元に戻せます。選んだ場所はこの Mac の設定に保存し、プロジェクトファイルには保存しません。

実行ファイルは、設定で選んだもの、アプリ内、配置先フォルダ、Homebrew の場所の順に探します。見つからない場合や、モデルが無い場合は、メニューを実行したときと設定シートに案内が出ます。

### Homebrew のバイナリについて

Homebrew の `whisper-cli` はシンボリックリンクです。Movie Cut はリンクの先(実体のパス)を調べ、実体が利用者のもので、他の人が書き換えられないことを確かめてから実行します。自分で何かする必要はありません。この確認を通らない場合は、設定画面にその理由が出ます。

## 4. 使い方

- **アプリ**: 音のあるクリップを選び、メニュー「出力 ▸ 音声から字幕を作る(Whisper)…」。認識した文が「字幕」レイヤーに入ります。1 回で元に戻せ、途中でキャンセルできます。
- **CLI**:
  ```sh
  moviecut-cli transcribe --engine whisper --locale ja-JP ...
  ```
  `--engine` は `apple`(既定)か `whisper`。`--locale ja-JP` は Whisper では言語コード `ja` として渡されます。その他の引数は `moviecut-cli transcribe` の usage を見てください。

## 5. ライセンス

- whisper.cpp は MIT ライセンスです。
- Whisper のモデルも MIT ライセンスで公開されています。
- ただし、ライセンスは各配布元(whisper.cpp のリポジトリ、Hugging Face のモデルページ)の表記に従ってください。Movie Cut はこれらを同梱・再配布しないので、`docs/同梱素材のライセンス.md` の対象外です。

## 6. 困ったとき

- 「whisper.cpp が見つかりません」: 上の 1 と 3 を確認。
- 「モデルが見つかりません」: `ggml-*.bin` を配置先に置くか、設定画面で選ぶ。
- 認識に時間がかかる: 長い素材は時間がかかります(制限時間は素材の長さに応じて最大 1 時間)。小さいモデルにすると速くなりますが精度は下がります。
