local trail = require('tshjkl.trail')
local nav = require('tshjkl.nav')

local M = {}

---@class TshjklKeymaps
---@field toggle string
---@field toggle_outer string
---@field parent string
---@field next string
---@field prev string
---@field child string
---@field toggle_named string

---@class TshjklMarks
---@field parent vim.api.keyset.set_extmark
---@field child vim.api.keyset.set_extmark
---@field next vim.api.keyset.set_extmark
---@field prev vim.api.keyset.set_extmark
---@field current vim.api.keyset.set_extmark

---@alias Binds fun(bind: fun(lhs: string, rhs: fun(t: Trail): nil), tshjkl: {exit: fun(drop_to_normal?: boolean), set_node: (fun(node: TSNode): nil), current_node: fun(): TSNode})

---@class TshjklConfig
---@field select_current_node boolean
---@field keymaps TshjklKeymaps
---@field marks TshjklMarks
---@field binds? Binds

---@type TshjklConfig
local default_config = {
  -- false to highlight only. Note that enabling this will hide the highlighting of child nodes
  select_current_node = true,
  keymaps = {
    toggle = '<M-v>',
    toggle_outer = '<S-M-v>',

    -- these are only bound when we're toggled on on
    parent = 'h',
    next = 'j',
    prev = 'k',
    child = 'l',
    swap_next = 'J',
    swap_prev = 'K',
    first_sibling = 'gg',
    last_sibling = 'G',
    toggle_named = '<S-M-n>', -- named mode skips unnamed nodes
  },
  marks = {
    parent = { -- these are extmark options (:h nvim_buf_set_extmark)
      -- you could add e.g. virt_text, sign_text
      hl_group = 'Comment',
    },
    child = {
      hl_group = 'Error',
    },
    next = {
      hl_group = 'WarningFloat',
    },
    prev = {
      hl_group = 'InfoFloat',
    },
    current = {
      hl_group = 'Substitute',
    },
  },
  binds = function(bind, tshjkl)
    bind('<Esc>', function()
      tshjkl.exit(true)
    end)

    bind('q', function()
      tshjkl.exit(true)
    end)
  end,
}

M.ns = vim.api.nvim_create_namespace('tshjkl')

M.marks = {}

local visual_mode_leave = (function()
  -- The ModeChange event fires after feedkeys of select_position
  -- select_position includes an <esc> to move to normal mode before
  -- visual again, so we need to ignore this first visual to normal change
  local should_ignore_next = false

  return {
    ignore_next = function()
      should_ignore_next = true
    end,
    handle_exit_visual = function()
      if should_ignore_next then
        should_ignore_next = false
      elseif M.on then
        M.exit()
      end
    end,
  }
end)()

---@alias Point { row: number, col: number }
---@alias NodePosition { start: Point, stop: Point }

---@param pos NodePosition
---@return nil
local function select_position(pos)
  local keys = pos.start.row + 1 .. 'G0'

  if pos.start.col > 0 then
    keys = keys .. pos.start.col .. 'l'
  end

  if pos.stop.col > 0 then
    keys = keys .. 'v' .. pos.stop.row + 1 .. 'G0'
    keys = keys .. pos.stop.col - 1 .. 'l'

    if vim.o.selection == 'exclusive' then
      keys = keys .. 'l'
    end
  else
    keys = keys .. 'v' .. pos.stop.row .. 'G$'
  end

  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes('<Esc>' .. keys, true, false, true),
    'n',
    true
  )

  if vim.api.nvim_get_mode().mode == 'v' then
    visual_mode_leave.ignore_next()
  end
end

local function clear_positions()
  vim.api.nvim_buf_clear_namespace(0, M.ns, 0, -1)
end

---@param pos NodePosition
---@param name string
---@return nil
local function show_position(pos, name)
  if M.marks[name] ~= nil then
    vim.api.nvim_buf_del_extmark(0, M.ns, M.marks[name])
  end

  M.marks[name] = vim.api.nvim_buf_set_extmark(
    0,
    M.ns,
    pos.start.row,
    pos.start.col,
    vim.tbl_extend('force', {
      end_row = pos.stop.row,
      end_col = pos.stop.col,
      strict = false,
    }, M.opts.marks[name] or {})
  )
end

---@param node TSNode
---@return NodePosition
local function node_position(node)
  local start_row, start_col, stop_row, stop_col = node:range()

  return {
    start = {
      row = start_row,
      col = start_col,
    },
    stop = {
      row = stop_row,
      col = stop_col,
    },
  }
end

---@param node TSNode | nil
---@param name string
---@return nil
local function show_node(node, name)
  if node == nil then
    return
  end

  show_position(node_position(node), name)
end

---@type TSNode | nil
M.current_node = nil

local winbar
do
  local original

  winbar = {
    update = function()
      if original == nil then
        original = vim.wo.winbar
      end

      vim.wo.winbar = '-- '
        .. (M.nodewise_start_position and 'VISUAL ' or '')
        .. (nav.is_named_mode() and 'NODE ' or 'NODE(all) ')
        .. (M.opts.select_current_node and 'SELECT ' or '')
        .. '-- '
        .. (M.current_node and M.current_node:type() or '')
    end,
    close = function()
      vim.wo.winbar = original
      original = nil
    end,
  }
end

---@param posA NodePosition
---@param posB NodePosition
local function join_positions(posA, posB)
  ---@param pointA Point
  ---@param pointB Point
  local function compare(pointA, pointB)
    if pointA.row ~= pointB.row then
      return pointA.row < pointB.row
    end

    if pointA.col ~= pointB.col then
      return pointA.col < pointB.col
    end

    return false
  end

  local earliest_first
  do
    local positions = {
      posA.start,
      posA.stop,
      posB.start,
      posB.stop,
    }

    table.sort(positions, compare)

    earliest_first = positions
  end

  return {
    start = earliest_first[1],
    stop = earliest_first[4],
  }
end

---@param node TSNode | nil
---@return nil
local function set_current_node(node)
  if node == nil then
    return
  end
  M.current_node = node

  winbar.update()

  clear_positions()
  local pos = node_position(node)
  vim.api.nvim_win_set_cursor(0, { pos.start.row + 1, pos.start.col })

  show_node(nav.parent(node), 'parent')
  show_node(nav.sibling(node, nav.op.next), 'next')
  show_node(nav.sibling(node, nav.op.prev), 'prev')

  if M.opts.select_current_node then
    if M.nodewise_start_position ~= nil then
      local union = join_positions(pos, M.nodewise_start_position)

      select_position(union)
    else
      select_position(pos)
    end
  else
    show_node(node, 'current')
    show_node(nav.child(node), 'child')
  end
end

---@param current_node TSNode | nil
---@param target_node TSNode | nil
---@return TSNode | nil
local function swap_nodes(current_node, target_node)
  if current_node == nil or target_node == nil then
    return
  end

  local function posnum(p)
    return p.row * 1e6 + p.col
  end

  local function put_text(pos, txt)
    vim.api.nvim_buf_set_text(
      0,
      pos.start.row,
      pos.start.col,
      pos.stop.row,
      pos.stop.col,
      txt
    )
  end

  ---@param pos NodePosition
  ---@return NodePosition
  local function trim_node_position(pos)
    local start_row, start_col = pos.start.row, pos.start.col
    local stop_row, stop_col = pos.stop.row, pos.stop.col

    -- buf_get_lines is end-row _exclusive_ (unlike buf_get_text) so we +1
    local lines_full =
      vim.api.nvim_buf_get_lines(0, start_row, stop_row + 1, false)
    local stop_line = lines_full[#lines_full]
    local stop_len = stop_line and #stop_line or 0
    -- Bug where if the end of the node is the end of the buffer (no trailing newline)
    -- we get an out of range error
    if #lines_full < stop_row - start_row + 1 then
      stop_row = stop_row - 1
      stop_col = stop_len
    end

    print(stop_line, stop_len)
    if stop_col > stop_len then
      stop_col = stop_len
    end

    local lines =
      vim.api.nvim_buf_get_text(0, start_row, start_col, stop_row, stop_col, {})

    -- trim leading whitespace
    while #lines > 0 do
      local first = lines[1] -- this fragment starts at (start_row, start_col) for the first line
      local fn = first:find('%S') -- first non-space (1-based in fragment)
      if fn then
        start_col = start_col + (fn - 1) -- adjust absolute col
        break
      end
      -- the selected part of this first line is all whitespace -> drop the whole line
      table.remove(lines, 1)
      start_row = start_row + 1
      start_col = 0
    end
    if #lines == 0 then
      return nil
    end

    -- trim trailing whitespace
    while #lines > 0 do
      local last = lines[#lines] -- this fragment ends at (stop_row, stop_col) for the last line
      local ln = last:match('.*()%S') -- position (1-based) of last non-space in the fragment
      if ln then
        if #lines == 1 then
          stop_col = start_col + ln
        else
          stop_col = ln
        end
        break
      end
      -- selected part of the last line is all whitespace -> drop it
      table.remove(lines) -- remove last
      stop_row = stop_row - 1
      if #lines == 0 then
        return nil
      end
      -- new last line: selection for it now extends to its full length
      stop_col = #lines[#lines]
    end

    return {
      start = { row = start_row, col = start_col },
      stop = { row = stop_row, col = stop_col },
    }
  end

  local a_pos = trim_node_position(node_position(current_node))
  local b_pos = trim_node_position(node_position(target_node))

  -- fetch texts (tables of lines)
  local a_text = vim.api.nvim_buf_get_text(
    0,
    a_pos.start.row,
    a_pos.start.col,
    a_pos.stop.row,
    a_pos.stop.col,
    {}
  )
  local b_text = vim.api.nvim_buf_get_text(
    0,
    b_pos.start.row,
    b_pos.start.col,
    b_pos.stop.row,
    b_pos.stop.col,
    {}
  )

  -- swap: replace later range first to avoid shifting earlier coordinates
  if posnum(a_pos.start) > posnum(b_pos.start) then
    put_text(a_pos, b_text)
    put_text(b_pos, a_text)
  else
    put_text(b_pos, a_text)
    put_text(a_pos, b_text)
  end

  -- compute where "current_node" (a) actually ended up
  local result_start_row, result_start_col, result_end_row, result_end_col
  if posnum(a_pos.start) < posnum(b_pos.start) then
    -- If a was before b: its final start is `b.start.row + (lenB - lenA)`
    result_start_row = b_pos.start.row + (#b_text - #a_text)
    result_start_col = b_pos.start.col
  else
    -- If a was after b: its final start is `b.start.row` (no further shift)
    result_start_row = b_pos.start.row
    result_start_col = b_pos.start.col
  end

  if #a_text == 0 then
    result_end_row = result_start_row
    result_end_col = result_start_col
  else
    if #a_text == 1 then
      result_end_row = result_start_row
      result_end_col = result_start_col + #a_text[1]
    else
      result_end_row = result_start_row + (#a_text - 1)
      result_end_col = #a_text[#a_text]
    end
  end

  -- Reparse and find the updated node that spans that range
  local parser = vim.treesitter.get_parser(bufnr)
  local tree = parser:parse()[1]
  local root = tree:root()
  local new_node = root:descendant_for_range(
    result_start_row,
    result_start_col,
    result_end_row,
    result_end_col
  )

  return new_node
end

M.keys = {}

local function unkeybind()
  local mode = M.opts.select_current_node and 'v' or 'n'

  for _, lhs in ipairs(M.keys) do
    pcall(vim.keymap.del, mode, lhs, { buffer = true })
  end
end

M.on = false

local function exit(enter_normal_mode)
  clear_positions()
  unkeybind()
  winbar.close()
  M.on = false

  if M.opts.select_current_node and enter_normal_mode then
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
  end

  M.current_node = nil
  M.nodewise_start_position = nil
end

M.exit = exit

---@param t Trail
---@param binds? Binds
local function keybind(t, binds)
  M.keys = {}

  local function bind(key, fn)
    local lhs = key
    table.insert(M.keys, lhs)

    local mode = M.opts.select_current_node and 'v' or 'n'

    vim.keymap.set(mode, lhs, fn, {
      buffer = true,
    })
  end

  local function next()
    set_current_node(t.from_sib_to_sib(nav.op.next))
  end

  local function prev()
    set_current_node(t.from_sib_to_sib(nav.op.prev))
  end

  local function swap_next()
    local new_node = swap_nodes(t.current(), t.from_sib_to_sib(nav.op.next))
    if new_node == nil then
      return
    end
    t.set_current_node(new_node)
    set_current_node(new_node)
  end

  local function swap_prev()
    local new_node = swap_nodes(t.current(), t.from_sib_to_sib(nav.op.prev))
    if new_node == nil then
      return
    end
    t.set_current_node(new_node)
    set_current_node(new_node)
  end

  local function parent()
    set_current_node(t.from_child_to_parent())
  end

  local function pos_is_end_of_line(pos)
    local line = vim.api.nvim_buf_get_lines(0, pos.row, pos.row + 1, false)
    return pos.col == #line
  end

  local function child()
    set_current_node(t.from_parent_to_child())
  end

  local function visual_select()
    select_position(node_position(t.current()))
    exit()
  end

  local function visual_select_back()
    local pos = node_position(t.current())

    local start
    if pos_is_end_of_line(pos.stop) then
      start = pos.stop
    else
      start = {
        row = pos.stop.row,
        col = pos.stop.col - 1,
      }
    end

    select_position({
      start = start,
      stop = {
        row = pos.start.row,
        col = pos.start.col + 1,
      },
    })

    exit()
  end

  local function nodewise_visual()
    if M.nodewise_start_position then
      M.nodewise_start_position = nil
      set_current_node(M.current_node) -- redraw
    else
      local n = t.current()
      M.nodewise_start_position = node_position(n)
      winbar.update()
    end
  end

  local function append()
    local pos = node_position(t.current())
    vim.api.nvim_win_set_cursor(0, { pos.stop.row + 1, pos.stop.col })

    if pos_is_end_of_line(pos.stop) then
      -- Insert at the end if we're at the end of the col
      vim.fn.feedkeys('a', 'n')
    else
      vim.cmd.startinsert()
    end

    exit()
  end

  local function prepend()
    local pos = node_position(t.current())
    vim.api.nvim_win_set_cursor(0, { pos.start.row + 1, pos.start.col })
    vim.cmd.startinsert()
    exit()
  end

  local function open_above()
    local pos = node_position(t.current())
    vim.api.nvim_win_set_cursor(0, { pos.start.row + 1, 0 })
    vim.fn.feedkeys('O', 'n')
    exit()
  end

  local function open_below()
    local pos = node_position(t.current())
    vim.api.nvim_win_set_cursor(0, { pos.stop.row + 1, 0 })
    vim.fn.feedkeys('o', 'n')
    exit()
  end

  local function innermost()
    set_current_node(t.move_innermost())
  end

  local function outermost()
    set_current_node(t.move_outermost())
  end

  local function first_sibling()
    set_current_node(t.from_sib_to_sib(nav.op.first))
  end

  local function last_sibling()
    set_current_node(t.from_sib_to_sib(nav.op.last))
  end

  local function toggle_named()
    nav.set_named_mode(not nav.is_named_mode())
    winbar.update()
  end

  bind(M.opts.keymaps.toggle, function()
    exit(true)
  end)
  bind(M.opts.keymaps.toggle_outer, function()
    exit(true)
  end)
  bind(M.opts.keymaps.next, next)
  bind(M.opts.keymaps.prev, prev)
  bind(M.opts.keymaps.swap_next, swap_next)
  bind(M.opts.keymaps.swap_prev, swap_prev)
  bind(M.opts.keymaps.parent, parent)
  bind(M.opts.keymaps.child, child)
  bind('H', outermost)
  bind('L', innermost)
  bind('b', visual_select_back)
  bind('v', M.opts.select_current_node and nodewise_visual or visual_select)
  bind('a', append) -- I don't think these work with select_current_node
  bind('i', prepend)
  bind('o', open_below)
  bind('<S-o>', open_above)
  bind(M.opts.keymaps.last_sibling, last_sibling)
  bind(M.opts.keymaps.first_sibling, first_sibling)
  bind(M.opts.keymaps.toggle_named, toggle_named)

  local binds_api = {
    exit = exit,
    current_node = function()
      return t.current()
    end,
    set_node = function(node)
      t.set_current_node(node)
      set_current_node(node)
    end,
    parent = nav.parent,
  }

  if binds then
    binds(bind, binds_api)
  end

  if vim.b.tshjkl_binds then
    vim.b.tshjkl_binds(bind, binds_api)
  end
end

---@param outermost boolean
local function enter(outermost)
  local t = trail.start()
  if t == nil then
    return
  end

  if outermost then
    t.move_outermost()
  end

  set_current_node(t.current())
  keybind(t, M.opts.binds)
  M.on = true
end

local function keybind_global(opts)
  vim.keymap.set('n', opts.keymaps.toggle, enter, { desc = 'tshjkl toggle' })

  vim.keymap.set('n', opts.keymaps.toggle_outer, function()
    enter(true)
  end, { desc = 'tshjkl toggle_outer' })

  if M.opts.select_current_node then
    vim.api.nvim_create_autocmd('ModeChanged', {
      pattern = 'v:*',
      callback = visual_mode_leave.handle_exit_visual,
    })
  end
end

M.did_setup = false

function M._plugin_setup()
  if M.did_setup then
    return
  end

  M.setup()
end

function M.setup(opts)
  M.opts = vim.tbl_deep_extend('force', default_config, opts or {})

  keybind_global(M.opts)

  M.did_setup = true
end

return M
