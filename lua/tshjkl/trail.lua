local nav = require('tshjkl.nav')

local M = {}

---@class Node
---@field node TSNode
---@field parent? Node
---@field child? Node

---@class Trail
---@field from_child_to_parent fun(): TSNode | nil
---@field from_parent_to_child fun(): TSNode | nil
---@field from_sib_to_sib fun(op: Op): TSNode | nil
---@field current fun(): TSNode
---@field move_innermost fun(): TSNode | nil
---@field move_outermost fun(): TSNode | nil
---@field set_current_node fun(tsnode: TSNode) : nil

---@param node TSNode
-- This is for automatically expanding the initial selection to the largest node on a line or lines
-- So when you start the mode, it selects the "line node" or whatever the closest equivalent to that is.
-- That is more convenient than selecting the smallest node that the cursor is on.
function find_largest_ancestor_on_same_lines(start_node)
  local node = start_node
  local start_row, start_col, stop_row, stop_col = node:range()

  while node do
    local _node = node:parent()
    if _node == nil then
      return node
    end
    local _start_row, _start_col, _stop_row, _stop_col = _node:range()
    if _stop_col == 0 then
      _stop_row = _stop_row - 1
    end

    if _start_row < start_row or _stop_row > stop_row then
      -- We expanded too far (we expanded to another line or lines), so stop here
      return node
    end
    node = _node
  end
end

---@return Trail | nil
function M.start()
  local ok, start_node =
    pcall(vim.treesitter.get_node, { ignore_injections = false })

  if not ok then
    vim.notify('Treesitter node not found', vim.log.levels.ERROR)
    return
  end

  ---@type Node
  local current = { node = find_largest_ancestor_on_same_lines(start_node) }

  ---@return TSNode | nil
  local function from_child_to_parent()
    local parent = nav.parent(current.node)
    if parent == nil then
      return
    end

    if current.parent == nil or current.parent.node ~= start_node then
      current.parent = {
        node = parent,
        child = current,
      }
    end

    current = current.parent
    ---@cast current -nil

    return current.node
  end

  ---@return TSNode | nil
  local function from_child_to_linewise_ancestor()
    -- Like from_child_to_parent but when expanding,
    -- chooses the largest node with the same range of lines as the parent
    local parent = find_largest_ancestor_on_same_lines(nav.parent(current.node))
    if parent == nil then
      return
    end

    if current.parent == nil or current.parent.node ~= start_node then
      current.parent = {
        node = parent,
        child = current,
      }
    end

    current = current.parent
    ---@cast current -nil

    return current.node
  end

  ---@return TSNode | nil
  local function from_parent_to_child()
    if current.child == nil then
      local child = nav.child(current.node)

      if child == nil then
        return
      end

      current.child = {
        node = child,
        parent = current,
      }
    end

    current = current.child
    ---@cast current -nil

    return current.node
  end

  local function has_smaller_range_of_lines(inner_node, outer_node)
    print(vim.inspect(inner_node))
    local start_row_inner, start_col_inner, stop_row_inner, stop_col_inner =
      inner_node:range()
    local start_row_outer, start_col_outer, stop_row_outer, stop_col_outer =
      outer_node:range()
    return start_row_inner > start_row_outer and stop_row_inner < stop_row_outer
  end

  local function find_linewise_descendant()
    local to_scan = { current.node }
    if current.child then
      table.insert(to_scan, 1, current.child.node)
    end

    while #to_scan > 0 do
      local node = table.remove(to_scan, 1)
      if has_smaller_range_of_lines(node, current.node) then
        return node
      end

      local child = nav.child(node)
      while child do
        table.insert(to_scan, child)
        child = nav.sibling(child, nav.op.next)
      end
    end
  end

  ---@return TSNode | nil
  local function from_parent_to_linewise_descendant()
    -- Like from_parent_to_child but when finding the child,
    -- chooses the largest node with a smaller range of lines than the parent
    -- (i.e. it must choose a node with a smaller line range)

    -- If no descendants have a smaller range of lines
    -- (for example if the parent is only one line long),
    -- falls back to from_parent_to_child behavior

    local child = find_linewise_descendant()

    if child then
      current.child = {
        node = child,
        parent = current,
      }
    end

    return from_parent_to_child()
  end

  ---@param op Op
  ---@return TSNode | nil
  local function from_sib_to_sib(op)
    local sibling = nav.sibling(current.node, op)
    if sibling == nil then
      return
    end

    current = {
      node = sibling,
    }

    return current.node
  end

  ---@return TSNode | nil
  local function move_outermost()
    local parent = nav.parent(current.node)

    while parent ~= nil do
      from_child_to_parent()
      parent = nav.parent(current.node)
    end

    -- Real outermost node is the whole file so go in one child
    return from_parent_to_child()
  end

  ---@return TSNode
  local function move_innermost()
    local current_child = current

    while current_child ~= nil do
      current = current_child
      current_child = current_child.child
    end

    return current.node
  end

  return {
    from_child_to_parent = from_child_to_parent,
    from_child_to_linewise_ancestor = from_child_to_linewise_ancestor,
    from_parent_to_linewise_descendant = from_parent_to_linewise_descendant,
    from_parent_to_child = from_parent_to_child,
    from_sib_to_sib = from_sib_to_sib,
    current = function()
      return current.node
    end,
    move_innermost = move_innermost,
    move_outermost = move_outermost,

    --- Set current - this will reset the trail tree unless we set to the same node
    ---@param tsnode TSNode
    set_current_node = function(tsnode)
      if tsnode ~= current.node then
        start_node = tsnode

        current = {
          node = tsnode,
        }
      end

      return current
    end,
  }
end

return M
