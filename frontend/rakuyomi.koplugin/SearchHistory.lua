local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Trapper = require("ui/trapper")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("widgets/Menu")
local Icons = require("Icons")
local rapidjson = require("rapidjson")
local Paths = require("Paths")

local Backend = require("Backend")
local ErrorDialog = require("ErrorDialog")
local LoadingDialog = require("LoadingDialog")
local MangaSearchResults = require("MangaSearchResults")

local HISTORY_FILENAME = Paths.getHomeDirectory() .. "/search_history.json"
local MAX_ENTRIES = 100

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local SearchHistoryStore = {}

function SearchHistoryStore.load()
  local data = read_file(HISTORY_FILENAME)
  if not data or data == "" then return {} end
  local ok, obj = pcall(rapidjson.decode, data)
  if not ok or type(obj) ~= "table" or type(obj.entries) ~= "table" then
    return {}
  end
  return obj.entries
end

function SearchHistoryStore.save(entries)
  local ok, json = pcall(rapidjson.encode, { entries = entries })
  if not ok then return false end
  return write_file(HISTORY_FILENAME, json)
end

local function sanitize_query(query)
  if type(query) ~= "string" then return nil end
  local q = query:match("^%s*(.-)%s*$")
  if not q or q == "" then return nil end
  return q
end

function SearchHistoryStore.add(query)
  local q = sanitize_query(query)
  if not q then return end

  local entries = SearchHistoryStore.load()
  local lower = q:lower()
  local filtered = {}
  for _, e in ipairs(entries) do
    if type(e.query) == "string" and e.query:lower() ~= lower then
      table.insert(filtered, e)
    end
  end
  local entry = { query = q, ts = os.time() }
  table.insert(filtered, 1, entry)
  while #filtered > MAX_ENTRIES do table.remove(filtered) end
  SearchHistoryStore.save(filtered)
end

function SearchHistoryStore.clear()
  SearchHistoryStore.save({})
end

function SearchHistoryStore.removeAt(index)
  local entries = SearchHistoryStore.load()
  if index >= 1 and index <= #entries then
    table.remove(entries, index)
    SearchHistoryStore.save(entries)
  end
end

function SearchHistoryStore.list()
  return SearchHistoryStore.load()
end

--- @class SearchHistory: { [any]: any }
--- @field on_return_callback fun(): nil
local SearchHistory = Menu:extend {
  name = "search_history",
  is_enable_shortcut = false,
  is_popout = false,
  title = "Search history",
  with_context_menu = true,

  entries = nil,
  on_return_callback = nil,
}

function SearchHistory:init()
  self.entries = self.entries or {}
  self.width = Screen:getWidth()
  self.height = Screen:getHeight()
  local page = self.page
  Menu.init(self)
  self.page = page

  self.paths = { 0 }
  self.on_return_callback = nil

  self:updateItems()
end

function SearchHistory:onClose()
  UIManager:close(self)
  if self.on_return_callback then
    self.on_return_callback()
  end
end

function SearchHistory:updateItems()
  local entries = SearchHistoryStore.list()
  if #entries > 0 then
    self.item_table = self:generateItemTableFromEntries(entries)
    self.multilines_show_more_text = false
    self.items_per_page = nil
    self.single_line = true
  else
    self.item_table = self:generateEmptyViewItemTable()
    self.multilines_show_more_text = true
    self.items_per_page = 1
    self.single_line = false
  end

  Menu.updateItems(self)
end

function SearchHistory:generateItemTableFromEntries(entries)
  local item_table = {}
  for idx, e in ipairs(entries) do
    table.insert(item_table, {
      index = idx,
      query = e.query,
      text = e.query,
      -- Keep it simple; timestamp could be shown later
      mandatory = Icons.FA_MAGNIFYING_GLASS,
    })
  end
  return item_table
end

function SearchHistory:generateEmptyViewItemTable()
  return {
    {
      text = "No search history yet. Try searching for mangas!",
      dim = true,
      select_enabled = false,
    }
  }
end

function SearchHistory:onReturn()
  table.remove(self.paths)
  self:onClose()
end

function SearchHistory:onPrimaryMenuChoice(item)
  Trapper:wrap(function()
    local q = item.query
    if not q or q == "" then return end

    -- bump to top
    SearchHistoryStore.add(q)

    local onReturnCallback = function()
      UIManager:show(self)
    end

    local cancel = false
    local response = LoadingDialog:showAndRun(
      "Searching for \"" .. q .. "\"",
      function() return Backend.searchMangas(q) end,
      function()
        local cancelledMessage = InfoMessage:new { text = "Search cancelled." }
        UIManager:show(cancelledMessage)
        cancel = true
      end
    )

    if cancel then
      return
    end

    if response.type == 'ERROR' then
      ErrorDialog:show(response.message)
      return
    end

    local results = response.body

    local ui = MangaSearchResults:new {
      results = results,
      on_return_callback = onReturnCallback,
      covers_fullscreen = true,
      page = self.page,
    }
    ui.on_return_callback = onReturnCallback
    UIManager:show(ui)

    UIManager:close(self)
  end)
end

function SearchHistory:onContextMenuChoice(item)
  local dialog
  local buttons = {
    {
      {
        text = Icons.FA_TRASH_CAN .. " Delete",
        callback = function()
          UIManager:close(dialog)
          SearchHistoryStore.removeAt(item.index)
          self:updateItems()
        end
      },
      {
        text = Icons.FA_BROOM .. " Clear all",
        callback = function()
          UIManager:close(dialog)
          SearchHistoryStore.clear()
          self:updateItems()
        end
      },
    },
  }

  dialog = ButtonDialog:new {
    title = item.query,
    buttons = buttons,
  }
  UIManager:show(dialog)
end

function SearchHistory:show(onReturnCallback)
  local ui = SearchHistory:new {
    entries = SearchHistoryStore.list(),
    on_return_callback = onReturnCallback,
    covers_fullscreen = true,
  }
  ui.on_return_callback = onReturnCallback
  UIManager:show(ui)
end

SearchHistory.store = SearchHistoryStore

return SearchHistory
