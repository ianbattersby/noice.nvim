local require = require("noice.util.lazy")

local Util = require("noice.util")
local View = require("noice.view")
local Manager = require("noice.message.manager")

---@class NoiceNotifyOptions
---@field title string
---@field level? string|number Message log level
---@field merge boolean merge messages into one Notification or create separate notifications
---@field replace boolean Replace existing notification or create a new one
---@field on_open? function callback for when window opens|function|table
---@field on_close? function callback for when window opens|function|table
---@field render? notify.RenderFun|string
---@field timeout? integer
local defaults = {
  title = "Notification",
  merge = false,
  level = nil, -- vim.log.levels.INFO,
  replace = false,
  on_open = nil,
  on_close = nil,
}

---@class NotifyInstance
---@field notify fun(msg:string?, level?:string|number, opts?:table): notify.Record}

---@alias notify.RenderFun fun(buf:buffer, notif: Notification, hl: NotifyBufHighlights, config: notify.Config)

---@class NotifyView: NoiceView
---@field win? number
---@field buf? number
---@field notif notify.Record
---@field super NoiceView
---@diagnostic disable-next-line: undefined-field
local NotifyView = View:extend("NotifyView")

function NotifyView.dismiss()
  require("notify").dismiss({ pending = true, silent = true })
end

function NotifyView:is_available()
  return pcall(_G.require, "notify") == true
end

function NotifyView:update_options()
  self._opts = vim.tbl_deep_extend("force", defaults, self._opts)
end

function NotifyView:plain()
  return function(bufnr, notif)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, notif.message)
  end
end

---@param config notify.Config
---@param render? notify.RenderFun|string
---@return notify.RenderFun
function NotifyView:get_render(config, render)
  ---@type string|notify.RenderFun
  local ret = render or config.render()
  if type(ret) == "string" then
    if ret == "plain" then
      ret = self:plain()
    else
      ---@type notify.RenderFun
      ret = require("notify.render")[ret]
    end
  end
  return ret
end

---@param messages NoiceMessage[]
---@param render? notify.RenderFun|string
---@param content? string
function NotifyView:notify_render(messages, render, content)
  ---@param config notify.Config
  return function(buf, notif, hl, config)
    -- run notify view
    self:get_render(config, render)(buf, notif, hl, config)

    Util.tag(buf, "notify")

    ---@type string[]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local text = table.concat(lines, "\n")
    local idx = content and text:find(content, 1, true) or nil

    if idx then
      -- we found the offset of the content as a string
      local offset = #vim.split(text:sub(1, idx - 1), "\n")
      -- do our rendering
      self:render(buf, { offset = offset, highlight = true, messages = messages })
      -- in case we didn't find the offset, we won't highlight anything
    end

    -- resize notification
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      ---@type number
      local width = config.minimum_width()
      for _, line in pairs(lines) do
        width = math.max(width, vim.str_utfindex(line))
      end
      width = math.min(config.max_width() or 1000, width)
      local height = math.min(config.max_height() or 1000, #lines)
      Util.win_apply_config(win, { width = width, height = height })
    end
  end
end

---@alias NotifyMsg {content:string, messages:NoiceMessage[], title?:string, level?:string, opts?: table}

---@param msg NotifyMsg
function NotifyView:_notify(msg)
  local level = self._opts.level or msg.level

  local opts = {
    title = msg.title or self._opts.title,
    animate = not Util.is_blocking(),
    timeout = self._opts.timeout,
    replace = self._opts.replace and self.notif,
    keep = function()
      return Util.is_blocking()
    end,
    on_open = function(win)
      self:set_win_options(win)
      if self._opts.merge then
        self.win = win
      end

      -- Really not happy about using defer here :'(
      vim.defer_fn(function()
        if self._opts.on_open then
          local notif = self.notif

          vim.validate({
            ["on_open.fn"] = { self._opts.on_open, "f" },
            ["on_open.win"] = { win, "n" },
            ["on_open.notif"] = { notif, "t" },
          })

          self._opts.on_open(win, notif)
        end
      end, 100)
    end,
    on_close = function(win)
      self.notif = nil

      for _, m in ipairs(msg.messages) do
        m.opts.notify_id = nil
      end
      self.win = nil

      -- Really not happy about using defer here :'(
      vim.defer_fn(function()
        if self._opts.on_close then
          local notif = self.notif

          vim.validate({
            ["on_close.fn"] = { self._opts.on_close, "f" },
            ["on_close.win"] = { win, "n" },
            ["on_close.notif"] = { notif, "t" },
          })

          self._opts.on_close(win, notif)
        end
      end, 100)
    end,
    render = Util.protect(self:notify_render(msg.messages, self._opts.render, msg.content)),
  }

  if msg.opts then
    opts = vim.tbl_deep_extend("force", opts, msg.opts)
    if type(msg.opts.replace) == "table" then
      local m = Manager.get_by_id(msg.opts.replace.id)
      opts.replace = m and m.opts.notify_id or nil
    end
  end

  ---@type string?
  local content = msg.content

  if msg.opts and msg.opts.is_nil then
    content = nil
  end

  local id = require("notify")(content, level, opts)
  self.notif = id
  for _, m in ipairs(msg.messages) do
    m.opts.notify_id = id
  end
end

function NotifyView:show()
  ---@type NotifyMsg[]
  local todo = {}

  if self._opts.merge then
    table.insert(todo, {
      content = self:content(),
      messages = self._messages,
    })
  else
    for _, m in ipairs(self._messages) do
      table.insert(todo, {
        content = m:content(),
        messages = { m },
        title = m.opts.title,
        level = m.level,
        opts = m.opts,
      })
    end
  end
  self:clear()

  for _, msg in ipairs(todo) do
    self:_notify(msg)
  end
end

function NotifyView:hide()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
    self.win = nil
  end
end

return NotifyView
