local M = {}

---@enum Op
local op = {
  first = 'f',
  last = 'l',
  next = 'n',
  prev = 'p',
}

M.op = op

---@alias OpTable table<Op, fun(node: TSNode): TSNode | nil>

---@type OpTable
local named_sib_ops = {
  [op.first] = function(node)
    local parent = node:parent()
    if parent == nil then
      return
    end

    return parent:named_child(0)
  end,

  [op.last] = function(node)
    local parent = node:parent()
    if parent == nil then
      return
    end

    return parent:named_child(parent:named_child_count() - 1)
  end,

  [op.next] = function(node)
    return node:next_named_sibling()
  end,

  [op.prev] = function(node)
    return node:prev_named_sibling()
  end,
}

---@type OpTable
local unnamed_sib_ops = {
  [op.first] = function(node)
    local parent = node:parent()
    if parent == nil then
      return
    end

    return parent:child(0)
  end,

  [op.last] = function(node)
    local parent = node:parent()
    if parent == nil then
      return
    end

    return parent:child(parent:child_count() - 1)
  end,

  [op.next] = function(node)
    return node:next_sibling()
  end,

  [op.prev] = function(node)
    return node:prev_sibling()
  end,
}

local named = true

---@param named_ boolean
---@return nil
function M.set_named_mode(named_)
  named = named_
end

function M.is_named_mode()
  return named
end

---@param node TSNode
---@param op_ Op
function M.sibling(node, op_)
  if named then
    return named_sib_ops[op_](node)
  else
    return unnamed_sib_ops[op_](node)
  end
end

local function child_same_tree(node)
  if named then
    return node:named_child(0)
  else
    return node:child(0)
  end
end

---@param node TSNode
function M.child(node)
  local tree_child = child_same_tree(node)

  if tree_child then
    return tree_child
  end

  -- try to get an injected node
  local injected = vim.treesitter.get_node({ ignore_injections = false })

  if injected and injected:tree() ~= node:tree() then
    return injected
  end
end

local function parent_same_tree(node)
  if named then
    local parent_ = node:parent()
    while parent_ and not parent_:named() do
      parent_ = node:parent()
    end
    return parent_
  else
    return node:parent()
  end
end

local function same_range(node_a, node_b)
  local start_row_a, start_col_a, stop_row_a, stop_col_a = node_a:range()
  local start_row_b, start_col_b, stop_row_b, stop_col_b = node_b:range()
  return start_row_a == start_row_b
    and start_col_a == start_col_b
    and stop_row_a == stop_row_b
    and stop_col_a == stop_col_b
end

function parent_across_trees(node)
  local tree_parent = parent_same_tree(node)

  if tree_parent then
    return tree_parent
  end

  -- try to get smallest node in top-level tree instead
  local top_level = vim.treesitter.get_node()
  if top_level and top_level:tree() ~= node:tree() then
    return top_level
  end
end

-- Skip nodes that have the exact same start & end and don't have any siblings
-- We should skip those since they won't move the selection and don't have any siblings that we might be trying to get to.
local function parent_skip_useless(node)
  local target = node
  while true do
    local _target = parent_across_trees(target)
    if _target == nil then
      return nil
    end
    local has_navigable_siblings
    if named then
      has_navigable_siblings = node:next_named_sibling()
        or node:prev_named_sibling()
        or false
    else
      has_navigable_siblings = node:next_sibling()
        or node:prev_sibling()
        or false
    end
    if not same_range(_target, node) or has_navigable_siblings then
      return _target
    end

    target = _target
  end
end

---@param node TSNode
function M.parent(node)
  return parent_skip_useless(node)
end

return M
