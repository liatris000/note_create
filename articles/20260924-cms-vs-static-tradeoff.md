---
title: "小規模サイトにCMSは本当に要るか"
emoji: "🗂️"
type: "tech"
topics: ["nextjs", "cms", "staticsite", "architecture", "webdev"]
pattern: "comparison"
published: true
published_at: "2026-09-24 07:00"
cover_image: https://raw.githubusercontent.com/liatris000/zenn_create/main/images/20260924-cms-vs-static-tradeoff_thumbnail.png
---

:::message
この記事は、Claude Codeを執筆支援に使った "毎朝1本書く" 取り組みの一環で書いています。

- 目的: 自分のAI活用キャッチアップ。仕組み自体も毎月アップデートしていきます
- 体制: 題材選定・実装・下書きをClaude Codeで補助、Liatrisが動作確認と編集を経て公開判断
- 方針: Zennのガイドラインに真摯に向き合い、運営から指摘や警告があれば即座に取り組みを停止します

仕組みの全貌は[こちらの設計記事](https://zenn.dev/liatris/articles/20260701-zenn-kickoff)にまとめています。
:::

小規模なコーポレートサイト(数ページ〜十数ページ、更新頻度は月数回程度)を新規に作るとき、
「とりあえずCMSを入れる」が定石になりがちだ。だが実際に手を動かしてみると、CMSが担って
いる責務を分解した時点で、更新頻度と更新者のスキルセット次第では丸ごと不要になるケースが
見えてくる。「WordPressを使うか使わないか」の二択ではなく、CMSが担う責務(コンテンツ編集
UI・入稿フロー・プレビュー・公開反映)をそれぞれ独立した意思決定として切り出す方が、判断が
早い。

## 比較対象を責務で整理する

検討対象を3パターンに絞った。

- パターンA: WordPress(管理画面 + DB + テーマ)
- パターンB: ヘッドレスCMS(microCMS / Contentful 等) + 静的フロント
- パターンC: CMSなし(Markdown + Next.js の static export、更新はPRベース)

比較軸は「更新者に必要なスキル」「更新の反映速度」「運用コスト(セキュリティ対応・課金)」
「非エンジニアが自走できるか」の4点。パターンAは管理画面とDBの運用コストが重く、更新頻度
が月数回のサイトには明らかにオーバースペックなので、今回は実装検証の対象からは外し、
パターンB・Cを実際に動かして比較した。

## パターンB・Cを同じプロジェクトで動かす

コンテンツ取得元だけが違う実装を1つの Next.js static export プロジェクトに同居させ、
`CONTENT_SOURCE` 環境変数で切り替えられるようにした。

```js:lib/get-posts.js
// CONTENT_SOURCE=local (デフォルト) | cms でビルド時のコンテンツ取得元を切り替える。
// パターンC(Markdown直読み)とパターンB(ヘッドレスCMS API)の差分が
// このファイル1枚に閉じるように設計している。
const source = process.env.CONTENT_SOURCE === "cms" ? "cms" : "local";

function getAllPosts() {
  if (source === "cms") {
    return require("./get-posts-cms").getAllPosts();
  }
  return require("./get-posts-local").getAllPosts();
}

module.exports = { getAllPosts, source };
```

パターンCの `get-posts-local.js` は `content/posts/*.md` を `gray-matter` で読んで
`marked` でHTML化するだけ。パターンBの `get-posts-cms.js` は本来ヘッドレスCMSの
REST APIを `fetch` する想定の実装だが、このリポジトリにはCMSアカウントの認証情報が
ないので、実際のAPIと同じレスポンス形(`contents` / `totalCount` / `offset` / `limit`)
のローカル fixture を代わりに読ませている。

```js:lib/get-posts-cms.js
const FIXTURE_PATH = path.join(process.cwd(), "data/cms-response.sample.json");

function getAllPosts() {
  const raw = fs.readFileSync(FIXTURE_PATH, "utf-8");
  const { contents } = JSON.parse(raw);
  return contents
    .map((item) => ({
      slug: item.id,
      title: item.title,
      date: item.publishedAt.slice(0, 10),
      html: item.body,
    }))
    .sort((a, b) => (a.date < b.date ? 1 : -1));
}
```

最初は実際にmicroCMSのアカウントを作って繋ぎにいこうとしたが、Routine環境からの
サインアップ作業は自動化の対象外だと判断してやめた。代わりに、`fetch` 呼び出しを
fixtureの読み込みに差し替えるだけで実APIに繋ぎ替えられる形にして、比較の本質(責務の
所在)がぶれないようにした。

## 結果と考察

`npm run build:local` と `npm run build:cms` をそれぞれ実行し、ビルド時間を計測した
(Node.js 22.22.2 / Next.js 14.2.35)。

| モード | ビルド時間 | 生成ページ数 |
|---|---|---|
| local | 18.7秒 | 3(index + posts 2件) |
| cms | 16.8秒 | 3(index + posts 2件) |

ビルド時間はほぼ差がなかった。これは想定通りで、どちらもビルド時点ではローカルファイル
を読むだけの処理だからだ。差が出るのはビルドより手前、「コンテンツを更新してからビルドが
走るまで」の運用フローの方だった。

- パターンC: Markdown編集 → `git commit` → PR作成 → レビュー → マージ(4ステップ、
  レビューが必ず挟まる)
- パターンB: CMS管理画面でプレビュー確認 → 公開ボタン(2ステップ、レビューは無いが
  非エンジニアだけで完結する)

更新者がエンジニア中心で、かつ更新頻度が月数回程度ならパターンCの方がステップは少なく
運用コストも低い。逆に更新者に非エンジニアが混じる、または更新頻度がもっと高いなら、
パターンBの入稿UI・プレビューの価値が効いてくる。つまり「CMSが必要か」は更新頻度単体
ではなく、更新頻度と更新者のスキルセットの掛け合わせで決まる。

データアナリストとしてこの題材を見ると、CMSの要否を「責務ごとに分解して判断する」
アプローチは、データ基盤の要否判断(集計をExcelでやるかBIツールを導入するか)とほぼ
同じ構造をしている。「更新頻度」「更新者のスキル」のような具体的な変数に判断軸を
分解しておくと、次に似たような意思決定をする時にもそのまま使い回せる。

@[github](https://github.com/liatris000/liatris-20260924-cms-vs-static-tradeoff)

デモ: https://liatris000.github.io/liatris-20260924-cms-vs-static-tradeoff/
