# Codex対応 実装サマリー

## 概要
multi-agent-shogunシステムをClaude Codeのみならず、OpenAI Codexも使用できるように改修した。

## 変更内容

### 1. サブモジュール追加
- **URL**: https://github.com/openai/codex.git
- **パス**: ./codex
- **状態**: 初期化・クローン完了

### 2. 設定ファイル作成
**config/settings.yaml**
- 使用するAIエージェントの切替設定（`agent: claude | codex`）
- Claude/codex固有の設定（モデル、パス、オプション等）
- 言語・シェル・スクリーンショット設定

### 3. 出陣スクリプト改修
**shutsujin_departure.sh**
- エージェント設定読み込み機能追加
- `get_agent_command()` 関数：agent設定に応じた起動コマンド生成
- `get_agent_name()` 関数：エージェント名表示
- 起動プロセスをagent設定に応じて自動切替
- 指示書ファイルもagentに応じて自動選択

### 4. Codex用指示書作成
- **instructions/codex-shogun.md**: 将軍用指示書（Codex版）
- **instructions/codex-karo.md**: 家老用指示書（Codex版）
- **instructions/codex-ashigaru.md**: 足軽用指示書（Codex版）

### 5. ドキュメント更新
**CLAUDE.md**
- バージョンを1.1.0に更新
- Codex対応について追記
- エージェント切替方法を記載
- codexのビルド方法を記載

## 使用方法

### Codexを使用する場合

1. **設定ファイルを編集**
   ```yaml
   # config/settings.yaml
   agent: codex
   ```

2. **codexをビルド（必要な場合）**
   ```bash
   cd codex/codex-rs
   cargo build --release
   ```

3. **システムを起動**
   ```bash
   ./shutsujin_departure.sh
   ```

### Claude Codeを使用する場合（デフォルト）

1. **設定ファイルを確認**
   ```yaml
   # config/settings.yaml
   agent: claude  # デフォルト
   ```

2. **システムを起動**
   ```bash
   ./shutsujin_departure.sh
   ```

## 技術的な詳細

### エージェント検出優先順位（codexの場合）
1. `./codex/codex-rs/target/debug/codex`
2. `./codex/codex-rs/target/release/codex`
3. PATH上の `codex` コマンド

### 起動コマンドの違い

**Claude Code:**
- 将軍: `MAX_THINKING_TOKENS=0 claude --model opus --dangerously-skip-permissions`
- 家老・足軽: `claude --dangerously-skip-permissions`

**Codex:**
- 将軍: `MAX_THINKING_TOKENS=0 <codex-path> --dangerously-bypass-approvals-and-sandbox`
- 家老・足軽: `<codex-path> --dangerously-bypass-approvals-and-sandbox`

※ `config/settings.yaml` の `codex.options` で上書き可能

## 注意事項

- codexはnpmパッケージとしてもインストール可能：`npm install -g @openai/codex`
- codex用指示書が存在しない場合は既存のClaude用指示書を使用
- 両方のエージェントを並列使用する場合は別途設定が必要（現状は単一エージェント切替のみ対応）
