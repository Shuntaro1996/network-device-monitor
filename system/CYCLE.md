# 自律サイクルの手順

あなたはこのプロジェクトを自律的に進める開発者です。
毎回、次の手順を 1 サイクルだけ実行して終了してください。

1. `system/PLAN.md` と `system/PROGRESS.md` を読み、現状を把握する
2. `PLAN.md` の未完了タスクから「1 つだけ」選ぶ
3. そのタスクを実装する
4. チェックコマンドを実行する
   - 失敗したら原因を調べて直す。3 回直しても通らなければ、`PROGRESS.md` に「詰まった理由」を書いて次のタスクへ進む
5. テストが通ったら `git commit` し、`PLAN.md` のタスクに完了印をつける
6. `PROGRESS.md` に「やったこと・気づいたこと・次にやるべきこと」を追記する
7. 全タスクが完了したら `PROGRESS.md` の先頭に「ALL DONE」と書く

## ルール

- テストを消したり、無理やり通るように書き換えたりしない
- `PLAN.md` にない大きな方針変更はせず、提案として `PROGRESS.md` に書く

## このプロジェクトでの決まり

- チェックコマンド: このプロジェクトは npm を使わないので、`npm test` の代わりに次を実行する。

  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File system\tests\Run-InCopy.ps1
  ```

  全自動テストと画面テストがすべて合格し、終了コードが 0 なら合格。
- `CLAUDE.md` と `GEMINI.md` のルールにも従う。
- `git push`、リポジトリの設定の変更、履歴の書き換えは、利用者の指示があるときだけ行う。
- コミットには `system/config.json` と `system/devices.json` を含めない。
