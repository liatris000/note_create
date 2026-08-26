---
title: "Claude APIで学習ログのつまずきを構造化検出する"
emoji: "🧩"
type: "tech"
topics: ["claude", "claudeapi", "python", "ai", "automation"]
pattern: "implementation"
published: true
published_at: "2026-09-17 07:00"
cover_image: https://raw.githubusercontent.com/liatris000/zenn_create/main/images/20260917-learner-stuckpoint-mining_thumbnail.png
---

:::message
この記事は、Claude Codeを執筆支援に使った "毎朝1本書く" 取り組みの一環で書いています。

- 目的: 自分のAI活用キャッチアップ。仕組み自体も毎月アップデートしていきます
- 体制: 題材選定・実装・下書きをClaude Codeで補助、Liatrisが動作確認と編集を経て公開判断
- 方針: Zennのガイドラインに真摯に向き合い、運営から指摘や警告があれば即座に取り組みを停止します

仕組みの全貌は[こちらの設計記事](https://zenn.dev/liatris/articles/20260701-zenn-kickoff)にまとめています。
:::

小テストの正誤と、提出物への自由記述コメント。学習系サービスを使うほどこの2つは溜まっていくが、大半はテキストのまま流れて終わる。「どこでつまずいているか」を拾い上げる工程が無いと、ログはただのログのままだ。Claude API の構造化出力(tool use)でこの自由記述をパースし、単元 x つまずき種別で集計するところまでを実装した。

## アーキテクチャ

- 入力: 学習ログ(小テストの正誤 + 自由記述コメント)。個人情報を含まない合成データを12件用意した
- 抽出: Claude API の tool use を `tool_choice` で強制し、単元・つまずき種別・確信度・根拠を1件ずつ構造化して抽出
- 集計: 単元 x つまずき種別でクロス集計
- 出力: 静的 HTML レポート(GitHub Pages でそのまま公開できる形)

```mermaid
flowchart LR
  A[学習ログ] --> B[Claude API 構造化出力]
  B --> C[つまずき種別 + 単元 + 確信度]
  C --> D[単元 x 種別 集計]
  D --> E[静的HTMLレポート]
```

## 実装: つまずき種別を5種の固定カテゴリに絞る

最初に悩んだのは、つまずき種別を固定カテゴリにするか自由記述にするかだった。自由記述にすれば個々のログのニュアンスは残せるが、その代わり「単元 x 種別」のクロス集計ができなくなる。逆に固定カテゴリだと集計はしやすいが、粒度が粗くなって情報が削られる。今回は `concept_gap`(概念理解の不足)/ `calculation_slip`(計算・手順のミス)/ `misread_instruction`(問題文の読み違い)/ `time_pressure`(時間切れ・見直し不足)/ `other` の5種に固定し、その代わり `evidence` フィールドにコメントからの引用根拠を必ず添えさせることでニュアンスの欠落を補うことにした。カテゴリは丸めるが、なぜそのカテゴリに分類したかの手がかりは残す、という折衷案になっている。

Pydantic モデルで抽出スキーマを定義し、`model_json_schema()` でそのまま tool 定義に変換する。

```python:stuckpoint_mining.py
class StuckpointRecord(BaseModel):
    unit: str = Field(description="つまずきが起きている単元名(ログのunit_hintを踏まえて正規化する)")
    category: str = Field(
        description=(
            "つまずきの種別。次のいずれか1つ: "
            "concept_gap(概念理解の不足) / calculation_slip(計算・手順のミス) / "
            "misread_instruction(問題文の読み違い) / time_pressure(時間切れ・見直し不足) / other(その他)"
        )
    )
    confidence: float = Field(description="分類の確信度(0.0〜1.0)")
    evidence: str = Field(description="分類根拠として引用したコメント中の一節(短く)")


def _model_to_tool(model: type[BaseModel], name: str, description: str) -> dict[str, Any]:
    schema = model.model_json_schema()
    schema.pop("title", None)
    return {"name": name, "description": description, "input_schema": schema}
```

呼び出し側は `tool_choice` で対象の tool を強制し、返ってきた `tool_use` ブロックの `input` をそのまま拾う。自由テキストで返されてパースに失敗する経路を潰すための措置で、これが無いとログによってはモデルが「分類できません」と平文で返してくることがある。

```python:stuckpoint_mining.py
def _call_structured(client: Any, *, system: str, user: str, tool: dict[str, Any]) -> dict[str, Any]:
    response = client.messages.create(
        model=MODEL,
        max_tokens=512,
        system=system,
        tools=[tool],
        tool_choice={"type": "tool", "name": tool["name"]},
        messages=[{"role": "user", "content": user}],
    )
    for block in response.content:
        if getattr(block, "type", None) == "tool_use" and block.name == tool["name"]:
            return block.input
    raise RuntimeError("tool_use ブロックが返らなかった(モデル or プロンプトを確認)")
```

ログ1件ずつに対してこの抽出を回し、`unit x category` で件数を集計する。

```python:stuckpoint_mining.py
def aggregate(results: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    """単元 x 種別 の件数を集計する。"""
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for r in results:
        record: StuckpointRecord = r["stuckpoint"]
        counts[record.unit][record.category] += 1
    return {unit: dict(cats) for unit, cats in counts.items()}
```

HTML レポートは棒グラフ用の JS ライブラリを入れず、集計件数に応じて `<span>` の `width` を計算するだけにした。GitHub Pages に静的ファイルとして置くだけで完結させたかったのと、外部依存が増えるとその分壊れる箇所が増えるので、今回のデータ量(12件)なら素の HTML + インラインスタイルで十分だった。

```bash
python3 stuckpoint_mining.py --input sample_logs.json --output index.html
```

CLI 自体を毎回本物の Claude API に投げてテストするのはコストがかかるし応答も非決定的なので、テストは `anthropic.Anthropic` クライアントをモックして tool 定義の組み立てと `tool_use` のパース経路だけを確認する形にした。GitHub Pages に置いているデモレポートも、同じ発想の固定ルールベースのモック応答(`--demo` オプション)で生成している。実データを使う場合は `ANTHROPIC_API_KEY` を設定して素のモードで実行すればいい。

## データアナリスト視点

自由記述ログを固定カテゴリの構造化データに変換してから集計する、という流れは、分析の前処理でテキストログをディメンションに落とし込む作業とほぼ同じ形をしている。「単元 x 種別」のクロス集計でつまずきが集中している箇所を洗い出す発想も、ファネル分析でどのステップの離脱率が高いかを見るのと近い。ただしカテゴリを固定した分、`other` に落ちるログを定期的に見返して分類軸自体を見直す運用が無いと、集計結果がだんだん実態とずれていきそうだ。

## 成果物

@[github](https://github.com/liatris000/liatris-20260917-learner-stuckpoint-mining)

デモ: https://liatris000.github.io/liatris-20260917-learner-stuckpoint-mining/
