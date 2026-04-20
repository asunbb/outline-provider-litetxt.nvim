# outline-provider-litetxt.nvim

[outline.nvim](https://github.com/hedyhli/outline.nvim) 的自定义 provider，为 txt(text) 文件提供 outline 符号提取。

基于 [tree-sitter-txt](https://github.com/asunbb/tree-sitter-txt) 解析器的 CST，提取前两级缩进段落作为 outline 条目。

## 安装

[lazy.nvim](https://lazy.folke.io/)

```lua
{
  "asunbb/outline-provider-litetxt.nvim",
  dependencies = {
    "asunbb/tree-sitter-txt",
    "hedyhli/outline.nvim"
  },
}
```

修改 outline opts 添加 litetxt 作为 provider，代码示例：
```lua
opts = {
  providers = {
    priority = {'litetxt', 'lsp', 'coc', 'markdown', 'norg', 'man'},
    litetxt = {},
  }
}
  ```

## 工作原理

outline.nvim 通过 `require('outline/providers/litetxt')` 发现 provider。本插件将模块放置在 `lua/outline/providers/litetxt.lua`，被 Neovim 的 runtimepath 机制自动发现。

provider 使用 litetxt treesitter parser 解析文本文件，从 CST 中提取前两级 `segment` 节点作为 outline 条目：

- 第一级 segment → SymbolKind Class（图标区分）
- 第二级 segment → SymbolKind Property

## litetxt 语法结构

```
document  -> repeat(segment)
segment   -> content + optional(indent, segment, ..., dedent)
content   -> /[^\n]+/
```

示例文本及其 outline：

```
标题一              ← 第一级
  子项 A            ← 第二级
  子项 B            ← 第二级
    细节            ← 第三级（不提取）
标题二              ← 第一级
```

## License

本项目基于 [MIT License](LICENSE) 开源。

## 免责声明

本项目代码主要由 coding agent（AI）生成
取用由人，自行判断和风险承担
因使用本代码导致的任何数据丢失，作者不承担责任
