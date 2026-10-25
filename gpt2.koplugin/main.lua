--[[--
GPT-2 on the device: continues a highlight, the current page, or a prompt you type.

The model (GPT-2 small, 124M parameters, 4-bit) runs in llama.cpp's llama-completion, both kept in this folder.
On a Kindle Scribe it writes about 13 tokens a second; the 8-bit model doesn't fit in the memory left over.

@module koplugin.GPT2
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Screen = require("device").screen
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local MODEL = "gpt2-Q4_0.gguf"
local BINARY = "llama-completion"
-- GPT-2 sees 1024 tokens; at ~4 characters a token this leaves room for the longest continuation
local MAX_PROMPT_CHARS = 2400
local SHOWN_PROMPT_CHARS = 400

local LENGTHS = { { _("Short"), 40 }, { _("Medium"), 80 }, { _("Long"), 160 } }
local TEMPERATURES = { { _("Careful (0.7)"), 0.7 }, { _("Normal (0.9)"), 0.9 }, { _("Wild (1.2)"), 1.2 } }

local GPT2 = WidgetContainer:extend{
    name = "gpt2",
    is_doc_only = false,
}

function GPT2:init()
    self.settings = G_reader_settings:readSetting("gpt2", { length = 80, temperature = 0.9 })
    Dispatcher:registerAction("gpt2_continue_page", { category = "none", event = "GPT2ContinuePage",
        title = _("GPT-2: continue this page"), reader = true })
    Dispatcher:registerAction("gpt2_prompt", { category = "none", event = "GPT2Prompt",
        title = _("GPT-2: write from a prompt"), general = true })
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("13_gpt2", function(this)
            return {
                text = _("Continue with GPT-2"),
                callback = function()
                    local text = util.cleanupSelectedText(this.selected_text.text)
                    this:onClose()
                    self:generate(text)
                end,
            }
        end)
    end
end

function GPT2:addToMainMenu(menu_items)
    menu_items.gpt2 = {
        text = _("GPT-2"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

function GPT2:menuItems()
    local function choices(key, list)
        local items = {}
        for _, choice in ipairs(list) do
            table.insert(items, {
                text = choice[1],
                checked_func = function() return self.settings[key] == choice[2] end,
                radio = true,
                callback = function() self.settings[key] = choice[2] end,
            })
        end
        return items
    end
    local items = {}
    if self.ui.document then
        table.insert(items, {
            text = _("Continue this page"),
            callback = function() self:onGPT2ContinuePage() end,
        })
    end
    table.insert(items, {
        text = _("Write from a prompt…"),
        callback = function() self:onGPT2Prompt() end,
        separator = true,
    })
    table.insert(items, {
        text_func = function() return T(_("Length: %1 tokens"), self.settings.length) end,
        sub_item_table = choices("length", LENGTHS),
    })
    table.insert(items, {
        text_func = function() return T(_("Temperature: %1"), self.settings.temperature) end,
        sub_item_table = choices("temperature", TEMPERATURES),
    })
    return items
end

-- The text on screen: crengine documents give it directly, PDFs as lines of word boxes.
function GPT2:pageText()
    local doc = self.ui.document
    if self.ui.rolling then
        local res = doc:getTextFromPositions({ x = 0, y = 0 }, { x = Screen:getWidth(), y = Screen:getHeight() }, true)
        return res and res.text
    end
    local boxes = doc:getTextBoxes(self.ui:getCurrentPage())
    if not boxes then return end
    local text = ""
    for _, line in ipairs(boxes) do
        local words = {}
        for _, box in ipairs(line) do
            if box.word then table.insert(words, box.word) end
        end
        if #words > 0 then
            if text:find("%a%-$") then
                text = text:sub(1, -2) .. table.concat(words, " ") -- rejoin a hyphenated word
            else
                text = text .. (text == "" and "" or " ") .. table.concat(words, " ")
            end
        end
    end
    return text
end

function GPT2:onGPT2ContinuePage()
    local text = self:pageText()
    if not text or not text:find("%S") then
        UIManager:show(InfoMessage:new{ text = _("There's no text on this page.") })
        return true
    end
    self:generate(text)
    return true
end

function GPT2:onGPT2Prompt()
    local dialog
    dialog = InputDialog:new{
        title = _("GPT-2"),
        input_hint = _("It was a dark and stormy night"),
        allow_newline = true,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Write"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    if not text:find("%S") then return end
                    UIManager:close(dialog)
                    self:generate(text)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

-- Keep the end of the text, starting at a word boundary.
local function tail(text, max)
    if #text <= max then return text, false end
    local cut = text:sub(-max)
    return (cut:match("^%S*%s+(.*)$") or cut), true
end

local function html(text)
    text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return (text:gsub("\n%s*\n", "</p><p>"):gsub("\n", "<br/>"))
end

-- Stop the running generation, if any, without showing what it wrote.
function GPT2:abandon()
    if self.pid then os.execute("kill " .. self.pid .. " 2>/dev/null") end
    self.pid = nil
end

-- Opens the GPT-2 window (or reuses `viewer`) and fills it in as llama-completion writes.
-- `original` is the text you chose; `previous` what GPT-2 already wrote after it, when asked to keep going.
function GPT2:generate(original, previous, viewer)
    self:abandon()
    previous = previous or ""
    local model_prompt = tail(((original .. previous):gsub("%s+$", "")), MAX_PROMPT_CHARS)
    local file = io.open(self.path .. "/prompt.txt", "w")
    if not file then
        UIManager:show(InfoMessage:new{ text = _("Couldn't write the prompt file.") })
        return
    end
    file:write(model_prompt)
    file:close()
    local output = self.path .. "/output.txt"
    os.remove(output)
    -- run in the background, writing to a file, and hand back its pid
    local cmd = string.format("cd %q && (./%s -m %s -t 2 -c 1024 -n %d --temp %s --repeat-penalty 1.3"
        .. " -no-cnv --no-display-prompt --no-warmup -f prompt.txt > output.txt 2>/dev/null </dev/null & echo $!)",
        self.path, BINARY, MODEL, self.settings.length, self.settings.temperature)
    local pipe = io.popen(cmd, "r")
    local pid = pipe and tonumber(pipe:read("*l"))
    if pipe then pipe:close() end
    if not pid then
        UIManager:show(InfoMessage:new{ text = _("Couldn't start GPT-2.") })
        return
    end
    self.pid = pid
    if not viewer then
        viewer = TextViewer:new{
            title = _("GPT-2"),
            text = "",
            text_format = "html",
            justified = false,
            add_default_buttons = true,
            buttons_table = { {} },
        }
        UIManager:show(viewer)
    end
    local started, shown = os.time(), nil
    local function poll()
        if self.pid ~= pid then return end -- replaced by another generation
        if not UIManager:isWidgetShown(viewer) then return self:abandon() end
        local f = io.open(output, "r")
        local written = f and f:read("*a") or ""
        if f then f:close() end
        local writing = lfs.attributes("/proc/" .. pid, "mode") ~= nil
        if writing then
            if written ~= shown then self:render(viewer, original, previous .. written, pid) end
            shown = written
            UIManager:scheduleIn(0.7, poll)
        else
            self.pid = nil
            self:render(viewer, original, ((previous .. written):gsub("%s+$", "")), nil, os.time() - started)
        end
    end
    self:render(viewer, original, previous, pid)
    UIManager:scheduleIn(0.5, poll)
end

-- Your text in grey, GPT-2's in bold; a Stop button while `pid` is writing, then Try again / Keep going.
function GPT2:render(viewer, original, generated, pid, seconds)
    local shown, cut = tail(original, SHOWN_PROMPT_CHARS)
    viewer.title = pid and _("GPT-2 · writing…") or T(_("GPT-2 · %1 s"), seconds)
    viewer.text = '<p><span style="color:#777777">' .. (cut and "…" or "") .. html(shown) .. "</span><b>"
        .. html(generated) .. "</b>" .. (pid and '<span style="color:#777777"> …</span>' or "") .. "</p>"
    local row = viewer.buttons_table[1]
    for i = #row, 1, -1 do row[i] = nil end
    if pid then
        row[1] = {
            text = _("Stop"),
            callback = function() os.execute("kill " .. pid .. " 2>/dev/null") end,
        }
    else
        row[1] = {
            text = _("Try again"),
            callback = function() self:generate(original, nil, viewer) end,
        }
        row[2] = {
            text = _("Keep going"),
            callback = function() self:generate(original, generated, viewer) end,
        }
    end
    viewer:init(true)
    pcall(function() viewer.scroll_widget:scrollToRatio(1) end)
    UIManager:setDirty(viewer, function() return "ui", viewer.frame.dimen end)
end

return GPT2
