-- outline.nvim 的 litetxt provider
-- 为 txt(text) 文件提供 outline 符号，基于 litetxt treesitter parser 的 AST
-- 显示第一级和第二级 segment 的预览
--
-- litetxt 语法结构 (grammar.js):
--   document  -> repeat(segment)
--   segment   -> content + optional(indent, segment, ..., dedent)
--   content   -> /[^\n]+/
--
-- AST 示例:
--   document
--     segment                 <- 第一级
--       content: "标题一"
--       segment               <- 第二级
--         content: "子项 A"
--       segment               <- 第二级
--         content: "子项 B"
--         segment             <- 第三级 (不提取)
--           content: "细节"
--     segment                 <- 第一级
--       content: "标题二"

local M = {
  -- provider 名称，对应 outline.nvim 配置中 providers.priority 列表里的项
  name = 'litetxt',
}

-- outline 条目名称最大 UTF8 字符数，超出截断并追加 "..."
local MAX_NAME_CHARS = 25

---从 treesitter AST 中递归提取 segment 节点，构建 outline 符号列表
---
---遍历 node 的子节点，对每个 segment:
---  1. 找到 content 子节点，提取其文本作为 outline 条目名称
---  2. 截断名称到 MAX_NAME_CHARS 个 UTF8 字符
---  3. 记录行范围，构建符号条目
---  4. 递归提取嵌套的子 segment 作为 children
---
---litetxt AST 中 segment 的子节点结构:
---  segment
---    content          <- 文本内容 (type == 'content')
---    _indent          <- 外部节点 (不可见)
---    segment          <- 嵌套子段
---    _newline         <- 外部节点 (不可见)
---    segment          <- 嵌套子段
---    ...
---    _dedent          <- 外部节点 (不可见)
---@param bufnr integer 缓冲区编号
---@param node TSNode 当前遍历的 treesitter 节点 (document 或 segment)
---@param depth integer 当前递归层级 (1 = 第一级, 2 = 第二级)
---@param max_depth integer 最大提取层级
---@return outline.ProviderSymbol[] 符号列表
local function get_segment_symbols(bufnr, node, depth, max_depth)
  -- 超过最大层级则停止递归
  if depth > max_depth then
    return {}
  end

  local symbols = {}

  -- 遍历当前节点的直接子节点
  for child in node:iter_children() do
    -- 只处理 segment 类型节点，跳过 _indent / _dedent / _newline 等外部节点
    if child:type() == 'segment' then

      -- 遍历 segment 的子节点，找到第一个 content 类型节点，提取其文本
      local name = ''
      for c in child:iter_children() do
        if c:type() == 'content' then
          name = vim.treesitter.get_node_text(c, bufnr) or ''
          break
        end
      end

      -- 截断为指定数量的 UTF8 字符，超出追加 "..."
      if vim.fn.strcharlen(name) > MAX_NAME_CHARS then
        name = vim.fn.strcharpart(name, 0, MAX_NAME_CHARS) .. '...'
      end

      -- 获取 segment 节点在缓冲区中的行范围 (0-indexed)
      local start_row, _, end_row, end_col = child:range()
      -- treesitter range 是半开区间 [start, end)，end 可能指向下一行开头 (end_col==0)
      -- outline.nvim 对 range_end 做 inclusive 检查，需要收缩到实际内容末行
      if end_col == 0 and end_row > start_row then
        end_row = end_row - 1
      end

      -- 当要提取子级 segment 时，将父级 range 收缩到第一个子 segment 之前，
      -- 避免父子的 range 重叠导致 outline 窗口中父子条目同时高亮
      -- litetxt 中 content 始终为单行，收缩后 range 仅覆盖父级自身内容行
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

      -- 构建符号条目，字段遵循 outline.nvim 的 ProviderSymbol 规范
      local entry = {
        -- LSP SymbolKind: 5=Class (第一级), 7=Property (第二级)，不同 kind 显示不同图标
        kind = depth == 1 and 5 or 7,
        -- 显示在 outline 窗口中的文本
        name = name,
        -- 点击时跳转的光标定位范围 (仅首行)
        selectionRange = {
          start = { character = 0, line = start_row },
          ['end'] = { character = 0, line = start_row },
        },
        -- segment 在缓冲区中占据的完整行范围 (首行到末行)
        range = {
          start = { character = 0, line = start_row },
          ['end'] = { character = 0, line = end_row },
        },
        -- 子级 segment 列表，构成树形结构
        children = {},
      }

      -- 递归提取嵌套的子 segment
      if depth < max_depth then
        entry.children = get_segment_symbols(bufnr, child, depth + 1, max_depth)
      end

      symbols[#symbols + 1] = entry
    end
  end

  return symbols
end

---判断当前缓冲区是否应使用此 provider
---条件: filetype 为 'text' (Neovim 对 .txt 文件的默认 filetype)，或匹配用户配置的 filetypes 列表
---@param bufnr integer 缓冲区编号
---@param config table? 用户配置中 providers.litetxt 的值
---@return boolean 是否支持该缓冲区
function M.supports_buffer(bufnr, config)
  local ft = vim.bo[bufnr].filetype
  if config and config.filetypes then
    for _, ft_check in ipairs(config.filetypes) do
      if ft_check == ft then
        return true
      end
    end
  end
  return ft == 'text'
end

---请求当前缓冲区的 outline 符号
---解析流程:
---  1. 获取 litetxt treesitter parser
---  2. 解析缓冲区内容得到 AST
---  3. 从 document 根节点提取前两级 segment
---  4. 通过 callback 将符号列表传递给 outline.nvim
---@param on_symbols fun(symbols?:outline.ProviderSymbol[], opts?:table) 符号就绪后的回调函数
---@param opts table outline.nvim 传入的选项表，原样传回 callback
function M.request_symbols(on_symbols, opts)
  local bufnr = vim.api.nvim_get_current_buf()

  -- 尝试获取 litetxt parser，失败则回调 nil 表示无符号
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'litetxt')
  if not ok or not parser then
    on_symbols(nil, opts)
    return
  end

  -- 解析缓冲区得到语法树
  local tree = parser:parse()[1]
  if not tree then
    on_symbols(nil, opts)
    return
  end

  local root = tree:root()
  -- 从 document 根节点开始提取，depth=1 表示第一级，max_depth=2 表示最多提取到第二级
  local symbols = get_segment_symbols(bufnr, root, 1, 2)

  -- 将符号列表传递给 outline.nvim 渲染 outline 窗口
  on_symbols(symbols, opts)
end

return M
