# outline provider 父子级 range 重叠导致双高亮

## 问题现象

光标移动到子段落时，outline 窗口中父段落和子段落同时被高亮。

参考文件第 31-32 行：
```
31  C++ ML 超分辨率与帧插值框架...       <- level-1 segment（父）
32    https://github.com/k4yt3x/video2x  <- level-2 segment（子）
```

光标在第 32 行时，outline 窗口中第 31 行和第 32 行对应的条目同时高亮。

## 根因分析

**tree-sitter 节点的 range 包含所有后代节点。** 一个 segment 的 tree-sitter range 从自身首行延伸到最后一个后代节点的末尾。

例如上面的结构中：
- 父 segment（第 31 行）的 tree-sitter range = `[30, 31]`（0-indexed），覆盖了第 32 行
- 子 segment（第 32 行）的 tree-sitter range = `[31, 31]`（0-indexed）

**outline.nvim 的高亮判定逻辑**：
```lua
-- sidebar.lua build_outline()
if hovered_line >= node.range_start and hovered_line <= node.range_end then
  node.hovered = true
end
```

当光标在第 32 行（hovered_line=31）时，父子两个条目的 range 都包含 31，两者同时被标记为 hovered。

## 修复方法

在 `get_segment_symbols` 中，计算完 segment 的 tree-sitter range 后，如果该 segment 有子级会被提取（`depth < max_depth`），将父级的 range_end 收缩到第一个子 segment 的前一行：

```lua
if depth < max_depth then
  for c in child:iter_children() do
    if c:type() == 'segment' then
      local child_start_row = c:start()
      if child_start_row > start_row and end_row >= child_start_row then
        end_row = child_start_row - 1
      end
      break
    end
  end
end
```

收缩后：
- 父 range = `[30, 30]` → 仅匹配光标在第 31 行
- 子 range = `[31, 31]` → 仅匹配光标在第 32 行
- 不再重叠，不会双高亮

## 安全性论证

**litetxt 的 content 始终是单行**（`content -> /[^\n]+/`），所以父级自身内容只占一行。收缩到子 segment 前一行后，父级 range 仍然完整覆盖其自身内容，不丢失信息。

**无子级的 segment**：循环找不到子 segment，不做任何调整，range 保持不变。

**depth == max_depth 的最深层 segment**：条件 `depth < max_depth` 不满足，range 保留完整 tree-sitter 范围（含未提取的更深层子级），cursor 在深层行仍能正确高亮。

**导航跳转**：outline.nvim 的跳转使用 `selectionRange`（仅首行），不受 `range` 收缩影响。

## 与 outline.nvim 内置 markdown provider 的一致性

outline.nvim 的内置 markdown provider（`markdown.lua` 第 83-89 行）也采用相同的 range 收缩策略来避免同级标题的 range 重叠。此修复与既有实践一致。

## 关键教训

1. **tree-sitter 节点 range 包含所有后代**，outline provider 不能直接透传给 outline.nvim，需要根据实际提取层级做裁剪
2. **outline.nvim 用 inclusive 范围检查判断高亮**，任何 range 重叠都会导致多条目同时高亮
3. **给 outline.nvim 的 `range` 字段应只覆盖"自身内容行"**，不应包含被独立提取的子级范围；`selectionRange` 负责导航跳转定位
