local addonName = ...

-- Key Bindings menu labels (Key Bindings > AddOns > Local Dictation)
BINDING_HEADER_LOCALDICTATION = "Local Dictation"
BINDING_NAME_LOCALDICTATION_RECORD = "Record / Stop (read by the helper after /reload)"
BINDING_NAME_LOCALDICTATION_TOGGLE = "Open / close dictation panel"
BINDING_NAME_LOCALDICTATION_CLEAR = "Clear dictation message"
BINDING_NAME_LOCALDICTATION_SEND = "Send dictation message"
BINDING_NAME_LOCALDICTATION_NEXT = "Next chat channel"
BINDING_NAME_LOCALDICTATION_PREV = "Previous chat channel"
BINDING_NAME_LOCALDICTATION_NEXTTARGET = "Next whisper target"
BINDING_NAME_LOCALDICTATION_FRIENDS = "Pick whisper target from friends"
BINDING_NAME_LOCALDICTATION_CLOSE = "Cancel / close dictation panel"
BINDING_NAME_LOCALDICTATION_RECORDING = "Helper: recording started (reserved)"
BINDING_NAME_LOCALDICTATION_PROCESSING = "Helper: transcription started (reserved)"
BINDING_NAME_LOCALDICTATION_PREPARE = "Helper: open preview for paste (reserved)"
BINDING_NAME_LOCALDICTATION_FAILED = "Helper: recording failed (reserved)"

local CHANNELS = {"SAY", "PARTY", "RAID", "INSTANCE_CHAT", "GUILD", "WHISPER"}
local LABELS = {SAY="Say", PARTY="Party", RAID="Raid", INSTANCE_CHAT="Instance", GUILD="Guild", WHISPER="Whisper"}
local CHANNEL_COLORS = {SAY={1,1,1}, PARTY={0.67,0.67,1}, RAID={1,0.5,0}, INSTANCE_CHAT={1,0.5,0}, GUILD={0.25,1,0.25}, WHISPER={1,0.5,1}}
-- Signal keys sent by the helpers. The Mac helper uses Ctrl-Shift-F13..F17; the Steam Deck / Linux
-- helper uses Ctrl-Shift-F6..F10 (F13+ may not pass through Xwayland/Wine). User hotkeys must not take them.
local HELPER_SIGNALS = {
    F13="RECORDING", F14="PROCESSING", F15="PREPARE", F16="SEND", F17="FAILED",
    F6="RECORDING", F7="PROCESSING", F8="PREPARE", F9="SEND", F10="FAILED",
}
-- The helper fires while the user's own trigger modifier (e.g. Command in Command-R) may still be held,
-- so the signal also arrives with META and/or ALT added. Accept every such variant.
local SIGNAL_PREFIXES = {"CTRL-SHIFT-", "CTRL-SHIFT-META-", "ALT-CTRL-SHIFT-", "ALT-CTRL-SHIFT-META-"}
local RESERVED = {}
for key in pairs(HELPER_SIGNALS) do
    for _, prefix in ipairs(SIGNAL_PREFIXES) do RESERVED[prefix .. key] = true end
end
local MAX_BYTES = 255
local MAX_RECENT = 8

local state = "idle"
local db

local function settings()
    if not db then
        if type(LocalDictationDB) ~= "table" then LocalDictationDB = {} end
        db = LocalDictationDB
        if not LABELS[db.channel] then db.channel = "PARTY" end
        if type(db.target) ~= "string" then db.target = "" end
        if db.targetKind ~= "bnet" then db.targetKind = "char" end
        if type(db.recent) ~= "table" then db.recent = {} end
    end
    return db
end

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
-- Remove characters that can't be in a chat message: macOS function-key characters (Unicode private use
-- U+F700-U+F8FF, which the helper's F13-F17 signals can leave in a focused box), line breaks from a paste,
-- and other control characters.
local function cleanMessage(s)
    s = (s or ""):gsub("\239[\156-\163][\128-\191]", "")
    s = s:gsub("[\r\n\t]", " ")
    s = s:gsub("[%z\1-\8\11\12\14-\31\127]", "")
    return s
end
local function setColor(tex, r, g, b, a)
    if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a or 1) else tex:SetTexture(r, g, b, a or 1) end
end
local function colorize(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r", math.floor(r*255), math.floor(g*255), math.floor(b*255), text)
end

local function channelProblem(ch)
    if ch == "PARTY" and IsInGroup and not IsInGroup() then return "You are not in a party." end
    if ch == "RAID" and IsInRaid and not IsInRaid() then return "You are not in a raid." end
    if ch == "INSTANCE_CHAT" and IsInGroup and LE_PARTY_CATEGORY_INSTANCE and not IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "You are not in an instance group." end
    if ch == "GUILD" and IsInGuild and not IsInGuild() then return "You are not in a guild." end
    return nil
end

local classTokenByName
local function classColor(className)
    if not className or not RAID_CLASS_COLORS then return nil end
    if not classTokenByName then
        classTokenByName = {}
        for _, t in ipairs({LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE}) do
            if type(t) == "table" then for token, name in pairs(t) do classTokenByName[name] = token end end
        end
    end
    return RAID_CLASS_COLORS[classTokenByName[className] or className:upper()]
end

------------------------------------------------------------------------
-- Friends
------------------------------------------------------------------------
local function requestFriends()
    if C_FriendList and C_FriendList.ShowFriends then pcall(C_FriendList.ShowFriends)
    elseif ShowFriends then pcall(ShowFriends) end
end

local function charFriends()
    local out = {}
    local n = (C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends()) or (GetNumFriends and GetNumFriends()) or 0
    for i = 1, n do
        local name, level, class, area, online
        if C_FriendList and C_FriendList.GetFriendInfoByIndex then
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info then name, level, class, area, online = info.name, info.level, info.className, info.area, info.connected end
        elseif GetFriendInfo then
            name, level, class, area, online = GetFriendInfo(i)
        end
        if name and name ~= "" then
            out[#out+1] = {kind="char", name=name, online=online and true or false, level=level, class=class, area=area}
        end
    end
    return out
end

local function bnetFriends()
    local out = {}
    if not BNGetNumFriends then return out end
    local n = BNGetNumFriends() or 0
    for i = 1, n do
        local id, accountName, tag, online, charName, client
        if C_BattleNet and C_BattleNet.GetFriendAccountInfo then
            local a = C_BattleNet.GetFriendAccountInfo(i)
            if a then
                id, accountName, tag = a.bnetAccountID, a.accountName, a.battleTag
                local g = a.gameAccountInfo
                online = g and g.isOnline or false
                if g then charName, client = g.characterName, g.clientProgram end
            end
        elseif BNGetFriendInfo then
            local _
            id, accountName, tag, _, charName, _, client, online = BNGetFriendInfo(i)
        end
        if id then
            out[#out+1] = {kind="bnet", id=id, accountName=accountName, tag=tag or "", online=online and true or false, charName=charName, client=client}
        end
    end
    return out
end

local function resolveBNet(tag)
    if tag == "" then return nil end
    for _, f in ipairs(bnetFriends()) do
        if f.tag == tag then return f.online and f.id or nil end
    end
    return nil
end

local function addRecent(name)
    name = trim(name)
    if name == "" then return end
    local recent = settings().recent
    for i = #recent, 1, -1 do if recent[i] == name then table.remove(recent, i) end end
    table.insert(recent, 1, name)
    while #recent > MAX_RECENT do table.remove(recent) end
end

local function byOnlineThenName(a, b)
    if a.online ~= b.online then return a.online end
    return (a.sortName or "") < (b.sortName or "")
end

-- Returns a flat list of rows: {header=text} or {label, detail, online, key, kind, value}
local function buildEntries(filter)
    filter = (filter or ""):lower()
    local function matches(...)
        if filter == "" then return true end
        for i = 1, select("#", ...) do
            local s = select(i, ...)
            if type(s) == "string" and s:lower():find(filter, 1, true) then return true end
        end
        return false
    end
    local rows, known = {}, {}
    local function section(title, list)
        if #list == 0 then return end
        table.sort(list, byOnlineThenName)
        local online = 0
        for _, e in ipairs(list) do if e.online then online = online + 1 end end
        rows[#rows+1] = {header=string.format("%s  (%d/%d online)", title, online, #list)}
        for _, e in ipairs(list) do rows[#rows+1] = e end
    end

    local chars = {}
    for _, f in ipairs(charFriends()) do
        known[f.name] = true
        if matches(f.name, f.area, f.class) then
            local label = f.name
            local c = f.online and classColor(f.class)
            if c then label = colorize(f.name, c.r, c.g, c.b) end
            local detail = "Offline"
            if f.online then detail = (f.level and f.level > 0 and ("Lv " .. f.level .. "  ") or "") .. (f.area or "") end
            chars[#chars+1] = {label=label, detail=detail, online=f.online, key="char:" .. f.name, kind="char", value=f.name, sortName=f.name:lower()}
        end
    end
    section("Friends", chars)

    local bnets = {}
    for _, f in ipairs(bnetFriends()) do
        if matches(f.tag, f.charName) then
            local label = f.accountName or f.tag
            if f.charName and f.charName ~= "" then label = label .. "  |cffaaaaaa(" .. f.charName .. ")|r" end
            local detail = "Offline"
            if f.online then detail = (f.client == "WoW" or f.client == BNET_CLIENT_WOW) and "In WoW" or "Battle.net" end
            bnets[#bnets+1] = {label=label, detail=detail, online=f.online, key="bnet:" .. f.tag, kind="bnet", value=f.tag, sortName=f.tag:lower()}
        end
    end
    section("Battle.net", bnets)

    local recents = {}
    for _, name in ipairs(settings().recent) do
        if not known[name] and matches(name) then
            recents[#recents+1] = {label=name, detail="Recent whisper", online=true, key="char:" .. name, kind="char", value=name, sortName=""}
        end
    end
    -- keep recency order: equal sortName + stable insertion is not guaranteed by table.sort, so add directly
    if #recents > 0 then
        rows[#rows+1] = {header="Recent whispers"}
        for _, e in ipairs(recents) do rows[#rows+1] = e end
    end
    return rows
end

local function currentTargetKey()
    local d = settings()
    return (d.targetKind == "bnet" and "bnet:" or "char:") .. d.target
end

------------------------------------------------------------------------
-- Main panel
------------------------------------------------------------------------
local BASE_HEIGHT, KEYS_HEIGHT = 400, 300
local panel = CreateFrame("Frame", "LocalDictationPanel", UIParent, "BackdropTemplate")
panel:SetSize(620, BASE_HEIGHT)
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background", edgeFile="Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=16, insets={left=4,right=4,top=4,bottom=4}})
panel:SetBackdropColor(0.04, 0.05, 0.08, 0.97)
tinsert(UISpecialFrames, "LocalDictationPanel") -- Escape closes it

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 20, -18); title:SetText("Local Dictation")
local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -5, -5)

-- Status line with a colored state dot
local dot = panel:CreateTexture(nil, "OVERLAY")
dot:SetSize(10, 10); dot:SetPoint("TOPLEFT", 22, -50)
local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
status:SetPoint("LEFT", dot, "RIGHT", 8, 0); status:SetWidth(560); status:SetJustifyH("LEFT")
local STATUS_COLORS = {idle={0.6,0.6,0.6}, info={0.4,0.7,1}, recording={1,0.2,0.2}, processing={1,0.65,0.1}, ready={0.3,0.95,0.4}, error={1,0.3,0.3}}
local function setStatus(text, kind)
    local c = STATUS_COLORS[kind] or STATUS_COLORS.info
    setColor(dot, c[1], c[2], c[3])
    status:SetText(text)
end
local pulse = 0
panel:SetScript("OnUpdate", function(_, elapsed)
    if state == "recording" or state == "processing" then
        pulse = pulse + elapsed
        dot:SetAlpha(0.35 + 0.65 * math.abs(math.sin(pulse * 3)))
    else dot:SetAlpha(1) end
end)

-- Channel selector
local channelLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
channelLabel:SetPoint("TOPLEFT", 20, -76); channelLabel:SetText("Channel")
local channelButtons = {}
local selectChannel -- forward
for i, ch in ipairs(CHANNELS) do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(92, 24)
    b:SetPoint("TOPLEFT", 20 + (i - 1) * 97, -92)
    b:SetText(LABELS[ch])
    b.channel = ch
    b:SetScript("OnClick", function() selectChannel(ch) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(LABELS[ch])
        local problem = channelProblem(ch)
        if problem then GameTooltip:AddLine(problem, 1, 0.3, 0.3) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    channelButtons[i] = b
end

-- Destination row
local toLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
toLabel:SetPoint("TOPLEFT", 20, -136); toLabel:SetText("To:")
local target = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
target:SetSize(220, 24); target:SetPoint("TOPLEFT", 56, -130); target:SetAutoFocus(false); target:SetMaxLetters(100)
local friendsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
friendsButton:SetSize(110, 24); friendsButton:SetPoint("LEFT", target, "RIGHT", 10, 0); friendsButton:SetText("Friends...")
local targetKind = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
targetKind:SetPoint("LEFT", friendsButton, "RIGHT", 10, 0)
local destText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
destText:SetPoint("TOPLEFT", 20, -136); destText:SetWidth(560); destText:SetJustifyH("LEFT")

-- Preview
local messageLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
messageLabel:SetPoint("TOPLEFT", 20, -166); messageLabel:SetText("Message preview")
local previewBG = CreateFrame("Frame", nil, panel, "BackdropTemplate")
previewBG:SetPoint("TOPLEFT", 20, -182); previewBG:SetSize(580, 150)
previewBG:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background", edgeFile="Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}})
previewBG:SetBackdropColor(0, 0, 0, 0.65)
local scroll = CreateFrame("ScrollFrame", nil, previewBG, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -10); scroll:SetPoint("BOTTOMRIGHT", -28, 10)
local preview = CreateFrame("EditBox", "LocalDictationPreview", scroll)
preview:SetMultiLine(true); preview:SetAutoFocus(false); preview:SetFontObject(ChatFontNormal)
preview:SetWidth(530); preview:SetHeight(130); preview:SetMaxBytes(4096)
scroll:SetScrollChild(preview)
previewBG:EnableMouse(true)
previewBG:SetScript("OnMouseDown", function() preview:SetFocus() end)
local count = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
count:SetPoint("TOPRIGHT", -20, -338)
local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", 20, -338)
hint:SetText("Enter sends  |  Esc closes  |  Controller: Record = start/stop, Send = submit")

-- Footer
local keysButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
keysButton:SetSize(100, 24); keysButton:SetPoint("BOTTOMLEFT", 20, 16); keysButton:SetText("Hotkeys")
local send = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
send:SetSize(110, 26); send:SetPoint("BOTTOMRIGHT", -20, 15); send:SetText("Send")
local cancel = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
cancel:SetSize(90, 24); cancel:SetPoint("RIGHT", send, "LEFT", -8, 0); cancel:SetText("Close")
local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clearButton:SetSize(90, 24); clearButton:SetPoint("RIGHT", cancel, "LEFT", -8, 0); clearButton:SetText("Clear")

------------------------------------------------------------------------
-- Friend picker popup
------------------------------------------------------------------------
local picker = CreateFrame("Frame", "LocalDictationFriendPicker", panel, "BackdropTemplate")
picker:SetSize(340, 310); picker:SetPoint("TOPLEFT", friendsButton, "BOTTOMLEFT", 0, -4)
picker:SetFrameStrata("FULLSCREEN_DIALOG"); picker:EnableMouse(true); picker:Hide()
picker:SetBackdrop(panel:GetBackdrop()); picker:SetBackdropColor(0.06, 0.07, 0.11, 0.99)
local searchLabel = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("TOPLEFT", 14, -16); searchLabel:SetText("Search")
local search = CreateFrame("EditBox", nil, picker, "InputBoxTemplate")
search:SetSize(150, 22); search:SetPoint("LEFT", searchLabel, "RIGHT", 12, 0); search:SetAutoFocus(false)
local refreshFriends = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
local pickerClose = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
pickerClose:SetPoint("TOPRIGHT", -2, -2)
pickerClose:SetScript("OnClick", function() picker:Hide() end) -- closes only the friend list
refreshFriends:SetSize(80, 22); refreshFriends:SetPoint("TOPRIGHT", -34, -11); refreshFriends:SetText("Refresh")
local pscroll = CreateFrame("ScrollFrame", nil, picker, "UIPanelScrollFrameTemplate")
pscroll:SetPoint("TOPLEFT", 10, -42); pscroll:SetPoint("BOTTOMRIGHT", -30, 10)
local plist = CreateFrame("Frame", nil, pscroll)
plist:SetSize(300, 1); pscroll:SetScrollChild(plist)
local rows = {}
local setWhisperTarget -- forward

local function getRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, plist)
    r:SetHeight(20)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * 20); r:SetPoint("RIGHT", plist, "RIGHT")
    r:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight", "ADD")
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 6, 0); r.text:SetWidth(180); r.text:SetJustifyH("LEFT")
    r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.detail:SetPoint("RIGHT", -4, 0); r.detail:SetWidth(110); r.detail:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function(self)
        local e = self.entry
        if e and e.value then setWhisperTarget(e.kind, e.value); picker:Hide() end
    end)
    rows[i] = r
    return r
end

local function refreshPicker()
    local entries = buildEntries(search:GetText())
    local current = currentTargetKey()
    if #entries == 0 then entries = {{header="No friends found. Add friends in the Social panel."}} end
    for i, e in ipairs(entries) do
        local r = getRow(i)
        r.entry = e
        if e.header then
            r.text:SetText("|cffffd100" .. e.header .. "|r"); r.text:SetWidth(290); r.detail:SetText("")
            r:EnableMouse(false)
        else
            local mark = (e.key == current) and "|cff40ff40> |r" or "   "
            r.text:SetWidth(180)
            r.text:SetText(mark .. (e.online and e.label or ("|cff808080" .. e.value .. "|r")))
            r.detail:SetText(e.detail or "")
            r:EnableMouse(e.online)
        end
        r:Show()
    end
    for i = #entries + 1, #rows do rows[i]:Hide(); rows[i].entry = nil end
    plist:SetHeight(math.max(1, #entries * 20))
    if LocalDictation_ResetPick then LocalDictation_ResetPick() end
end

-- Controller cursor in the friend list (D-pad up/down, A to pick).
local pickIndex
local function selectableRows()
    local out = {}
    for i, r in ipairs(rows) do
        if r:IsShown() and r.entry and r.entry.value and r.entry.online then out[#out+1] = i end
    end
    return out
end
local function highlightPick()
    for _, r in ipairs(rows) do r:UnlockHighlight() end
    local r = pickIndex and rows[pickIndex]
    if not r then return end
    r:LockHighlight()
    local top, view, cur = (pickIndex - 1) * 20, pscroll:GetHeight(), pscroll:GetVerticalScroll()
    if top < cur then pscroll:SetVerticalScroll(top)
    elseif top + 20 > cur + view then pscroll:SetVerticalScroll(math.max(0, top + 20 - view)) end
end
function LocalDictation_ResetPick()
    pickIndex = nil
    local current = currentTargetKey()
    for _, i in ipairs(selectableRows()) do
        if rows[i].entry.key == current then pickIndex = i; break end
    end
    highlightPick()
end
local function movePick(step)
    local sel = selectableRows()
    if #sel == 0 then return end
    local pos = 0
    for k, i in ipairs(sel) do if i == pickIndex then pos = k end end
    if pos == 0 then pos = step > 0 and 1 or #sel else pos = (pos - 1 + step) % #sel + 1 end
    pickIndex = sel[pos]
    highlightPick()
end
local function choosePick()
    local r = pickIndex and rows[pickIndex]
    if r and r.entry and r.entry.value then setWhisperTarget(r.entry.kind, r.entry.value); picker:Hide() end
end

search:SetScript("OnTextChanged", refreshPicker)
search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); picker:Hide() end)
search:SetScript("OnEnterPressed", function(self)
    for _, r in ipairs(rows) do
        if r:IsShown() and r.entry and r.entry.value and r.entry.online then
            setWhisperTarget(r.entry.kind, r.entry.value); picker:Hide(); return
        end
    end
    self:ClearFocus()
end)
refreshFriends:SetScript("OnClick", function() requestFriends(); refreshPicker() end)
local function openPicker()
    requestFriends()
    search:SetText("")
    picker:Show()
    refreshPicker()
end
friendsButton:SetScript("OnClick", function() if picker:IsShown() then picker:Hide() else openPicker() end end)

------------------------------------------------------------------------
-- Hotkey editor
------------------------------------------------------------------------
local HOTKEY_ACTIONS = {
    {"LOCALDICTATION_RECORD", "Record / Stop"},
    {"LOCALDICTATION_TOGGLE", "Open / close panel"},
    {"LOCALDICTATION_CLEAR", "Clear message"},
    {"LOCALDICTATION_SEND", "Send message"},
    {"LOCALDICTATION_NEXT", "Next channel"},
    {"LOCALDICTATION_PREV", "Previous channel"},
    {"LOCALDICTATION_NEXTTARGET", "Next whisper target"},
    {"LOCALDICTATION_FRIENDS", "Pick from friends"},
    {"LOCALDICTATION_CLOSE", "Cancel / close"},
}
local keysFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
keysFrame:SetPoint("TOPLEFT", 20, -358); keysFrame:SetPoint("TOPRIGHT", -20, -358); keysFrame:SetHeight(KEYS_HEIGHT - 10)
keysFrame:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background", edgeFile="Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}})
keysFrame:SetBackdropColor(0, 0, 0, 0.5)
keysFrame:Hide()
local keysTitle = keysFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
keysTitle:SetPoint("TOPLEFT", 12, -10); keysTitle:SetText("Hotkeys")
local keysStatus = keysFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
keysStatus:SetPoint("LEFT", keysTitle, "RIGHT", 12, 0); keysStatus:SetWidth(440); keysStatus:SetJustifyH("LEFT")
local DEFAULT_KEYS_HINT = "Click a slot, then press a key, mouse button or gamepad button. Right-click clears."
keysStatus:SetText(DEFAULT_KEYS_HINT)

local slotButtons = {}
local capture -- forward

local function keyText(key)
    if not key then return "|cff808080Not bound|r" end
    return (GetBindingText and GetBindingText(key, "KEY_")) or key
end

local function refreshKeys()
    for _, s in ipairs(slotButtons) do
        local keys = {GetBindingKey(s.action)}
        if not (capture and capture.slotButton == s) then s:SetText(keyText(keys[s.slot])) end
    end
end

local function saveBindings()
    if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
end

-- The helper cannot ask WoW for bindings, so the Record / Stop keys are written into
-- LocalDictationDB. WoW saves that file on /reload or logout, and the helper reads it.
local function gamepadCVar(name)
    if not GetCVar then return "" end
    local ok, value = pcall(GetCVar, name)
    return ok and value or ""
end
local exportedAtLogin -- what the saved file (and so the helper) has, captured when the addon loads
local function helperSignature(d)
    return (d.helperRecord1 or "") .. "|" .. (d.helperRecord2 or "") .. "|" .. (d.padShift or "") .. "|" .. (d.padCtrl or "") .. "|" .. (d.padAlt or "")
end
local function exportHelperKeys()
    local d = settings()
    local k1, k2 = GetBindingKey("LOCALDICTATION_RECORD")
    d.helperRecord1, d.helperRecord2 = k1 or "", k2 or ""
    d.padShift = gamepadCVar("GamePadEmulateShift")
    d.padCtrl = gamepadCVar("GamePadEmulateCtrl")
    d.padAlt = gamepadCVar("GamePadEmulateAlt")
    return helperSignature(d) ~= exportedAtLogin -- true: the helper will only see this after /reload
end

local reloadButton = CreateFrame("Button", nil, keysFrame, "UIPanelButtonTemplate")
reloadButton:SetSize(150, 22); reloadButton:SetPoint("BOTTOMRIGHT", -12, 10); reloadButton:SetText("Reload UI now")
reloadButton:SetScript("OnClick", function() ReloadUI() end)
reloadButton:Hide()
local reloadHint = keysFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
reloadHint:SetPoint("RIGHT", reloadButton, "LEFT", -10, 0); reloadHint:SetWidth(390); reloadHint:SetJustifyH("RIGHT")
reloadHint:SetText("Record / Stop changed: /reload so the helper can read it.")
reloadHint:Hide()
local function updateReloadHint()
    local pending = exportHelperKeys()
    reloadButton:SetShown(pending); reloadHint:SetShown(pending)
end

-- Plain typing keys would start recording while you type in chat.
local function isTypingKey(key)
    if not key then return false end
    if key:find("^ALT%-") or key:find("^CTRL%-") or key:find("^META%-") then return false end
    local bare = key:gsub("^SHIFT%-", "")
    return #bare == 1 or bare == "SPACE" or bare == "ENTER" or bare == "BACKSPACE" or bare == "TAB"
end

local function applyBinding(action, slot, newKey)
    if InCombatLockdown() then keysStatus:SetText("|cffff5555Cannot change hotkeys in combat.|r"); return end
    local keys = {GetBindingKey(action)}
    local old = keys[slot]
    if newKey and RESERVED[newKey] then
        keysStatus:SetText("|cffff5555" .. newKey .. " is reserved for the dictation helper.|r"); return
    end
    if newKey and action == "LOCALDICTATION_RECORD" and isTypingKey(newKey) then
        keysStatus:SetText("|cffff5555Record needs a modifier (Ctrl/Alt), an F-key or a gamepad button: " .. keyText(newKey) .. " is a typing key.|r"); return
    end
    if old then SetBinding(old) end
    local message = DEFAULT_KEYS_HINT
    if newKey then
        local previous = GetBindingAction(newKey)
        SetBinding(newKey, action)
        if previous and previous ~= "" and previous ~= action then
            local name = _G["BINDING_NAME_" .. previous] or previous
            message = "|cffffd100" .. keyText(newKey) .. " was unbound from: " .. name .. "|r"
        else
            message = "|cff40ff40Bound " .. keyText(newKey) .. ".|r"
        end
    end
    saveBindings()
    keysStatus:SetText(message)
    refreshKeys()
    updateReloadHint()
end

capture = CreateFrame("Button", nil, panel)
capture:SetAllPoints(panel); capture:SetFrameLevel(panel:GetFrameLevel() + 50); capture:Hide()
local captureShade = capture:CreateTexture(nil, "BACKGROUND"); captureShade:SetAllPoints(); setColor(captureShade, 0, 0, 0, 0.35)
local captureText = capture:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
captureText:SetPoint("CENTER"); captureText:SetText("Press a key for the hotkey...\n|cffaaaaaaEsc or left-click to cancel|r")

local IGNORED_KEYS = {LSHIFT=true, RSHIFT=true, LCTRL=true, RCTRL=true, LALT=true, RALT=true, LMETA=true, RMETA=true, UNKNOWN=true}
local function chord(key)
    local s = ""
    if IsAltKeyDown() then s = s .. "ALT-" end
    if IsControlKeyDown() then s = s .. "CTRL-" end
    if IsShiftKeyDown() then s = s .. "SHIFT-" end
    if IsMetaKeyDown and IsMetaKeyDown() then s = s .. "META-" end
    return s .. key
end

local function stopCapture()
    if not capture:IsShown() then return end
    capture:EnableKeyboard(false)
    if capture.EnableGamePadButton then capture:EnableGamePadButton(false) end
    capture:Hide()
    capture.slotButton = nil
    refreshKeys()
end

local function finishCapture(key)
    local s = capture.slotButton
    stopCapture()
    if s then applyBinding(s.action, s.slot, key) end
end

capture:SetScript("OnKeyDown", function(_, key)
    if key == "ESCAPE" then stopCapture(); return end
    if IGNORED_KEYS[key] then return end
    finishCapture(chord(key))
end)
capture:SetScript("OnMouseDown", function(_, button)
    local map = {MiddleButton="BUTTON3", Button4="BUTTON4", Button5="BUTTON5"}
    if map[button] then finishCapture(chord(map[button])) else stopCapture() end
end)
capture:SetScript("OnGamePadButtonDown", function(_, button) finishCapture(chord(button)) end)

local function startCapture(slotButton)
    if InCombatLockdown() then keysStatus:SetText("|cffff5555Cannot change hotkeys in combat.|r"); return end
    preview:ClearFocus(); target:ClearFocus(); search:ClearFocus()
    capture.slotButton = slotButton
    slotButton:SetText("|cffffd100Press a key...|r")
    capture:Show()
    capture:EnableKeyboard(true)
    if capture.SetPropagateKeyboardInput then capture:SetPropagateKeyboardInput(false) end
    if capture.EnableGamePadButton then capture:EnableGamePadButton(true) end
end

for i, a in ipairs(HOTKEY_ACTIONS) do
    local y = -34 - (i - 1) * 24
    local label = keysFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 14, y - 5); label:SetWidth(170); label:SetJustifyH("LEFT"); label:SetText(a[2])
    for slot = 1, 2 do
        local b = CreateFrame("Button", nil, keysFrame, "UIPanelButtonTemplate")
        b:SetSize(170, 22); b:SetPoint("TOPLEFT", 190 + (slot - 1) * 180, y)
        b.action, b.slot = a[1], slot
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then applyBinding(self.action, self.slot, nil) else startCapture(self) end
        end)
        slotButtons[#slotButtons+1] = b
    end
end

local function showKeys(show)
    if InCombatLockdown() and show then setStatus("Hotkeys can be changed after combat.", "error"); return end
    keysFrame:SetShown(show)
    panel:SetHeight(show and (BASE_HEIGHT + KEYS_HEIGHT) or BASE_HEIGHT)
    keysButton:SetText(show and "Hide hotkeys" or "Hotkeys")
    if show then keysStatus:SetText(DEFAULT_KEYS_HINT); refreshKeys() else stopCapture() end
end
keysButton:SetScript("OnClick", function() showKeys(not keysFrame:IsShown()) end)

------------------------------------------------------------------------
-- Destination and state handling
------------------------------------------------------------------------
local function updateDestination()
    local d = settings()
    for _, b in ipairs(channelButtons) do
        local selected = b.channel == d.channel
        local fs = b:GetFontString()
        if selected then
            b:LockHighlight()
            local c = CHANNEL_COLORS[b.channel]
            if fs then fs:SetTextColor(c[1], c[2], c[3]) end
        else
            b:UnlockHighlight()
            if fs then
                if channelProblem(b.channel) then fs:SetTextColor(0.5, 0.5, 0.5) else fs:SetTextColor(1, 0.82, 0) end
            end
        end
    end
    local whisper = d.channel == "WHISPER"
    toLabel:SetShown(whisper); target:SetShown(whisper); friendsButton:SetShown(whisper); targetKind:SetShown(whisper)
    destText:SetShown(not whisper)
    if whisper then
        if target:GetText() ~= d.target then target:SetText(d.target) end
        targetKind:SetText(d.targetKind == "bnet" and "Battle.net whisper" or (d.target ~= "" and "Character whisper" or "Type Name or Name-Realm"))
    else
        picker:Hide()
        local c = CHANNEL_COLORS[d.channel]
        local text = "Messages go to " .. colorize(LABELS[d.channel], c[1], c[2], c[3]) .. " chat."
        local problem = channelProblem(d.channel)
        if problem then text = text .. "  |cffff5555" .. problem .. "|r" end
        destText:SetText(text)
    end
    if picker:IsShown() then refreshPicker() end
end

selectChannel = function(ch)
    settings().channel = ch
    updateDestination()
    if ch == "WHISPER" and settings().target == "" then openPicker() end
end

setWhisperTarget = function(kind, value)
    local d = settings()
    d.channel = "WHISPER"; d.targetKind = kind == "bnet" and "bnet" or "char"; d.target = value or ""
    updateDestination()
end

local function updateCount()
    local text = preview:GetText() or ""
    local n = #text
    if n > MAX_BYTES then count:SetText("|cffff4040" .. n .. " / " .. MAX_BYTES .. " bytes - too long|r")
    elseif n > MAX_BYTES - 25 then count:SetText("|cffffa020" .. n .. " / " .. MAX_BYTES .. " bytes|r")
    else count:SetText(n .. " / " .. MAX_BYTES .. " bytes") end
    if n > 0 and state ~= "recording" and state ~= "processing" then send:Enable() else send:Disable() end
end

local function clear()
    preview:SetText(""); preview:ClearFocus(); target:ClearFocus(); updateCount()
end

local function showPanel()
    settings()
    updateDestination()
    panel:Show()
end

function LocalDictation_Close()
    state = "idle"; clear(); picker:Hide(); stopCapture(); panel:Hide()
end

function LocalDictation_Toggle()
    if panel:IsShown() then LocalDictation_Close(); return end
    state = "idle"; clear(); showPanel()
    setStatus("Type a message, or press your controller's Record button.", "idle")
end

-- The Record / Stop binding itself does nothing in WoW: the helper sees the same key press.
-- If no helper signal follows, explain what to check.
local lastSignal, lastRecordPress = 0, 0
local function signalled() lastSignal = GetTime() end
function LocalDictation_RecordPressed()
    lastRecordPress = GetTime()
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(1.5, function()
        if lastSignal >= lastRecordPress then return end
        if not panel:IsShown() then showPanel() end
        if exportHelperKeys() then
            setStatus("The helper has not read your new Record key yet. Type /reload, then try again.", "error")
        else
            setStatus("The helper did not react to Record. Check it is running with the bridge on and WoW in front.", "error")
        end
    end)
end

function LocalDictation_Recording()
    signalled()
    state = "recording"; clear(); picker:Hide(); stopCapture(); showPanel()
    setStatus("Recording... Press your Record button again to stop.", "recording")
end

function LocalDictation_Processing()
    signalled()
    state = "processing"; preview:ClearFocus(); updateCount(); showPanel()
    setStatus("Transcribing locally... waiting for the helper.", "processing")
end

function LocalDictation_Prepare()
    signalled()
    state = "receiving"; clear(); picker:Hide(); stopCapture(); showPanel()
    setStatus("Waiting for the helper to paste the transcript...", "processing")
    preview:SetFocus()
end

function LocalDictation_Failed()
    signalled()
    state = "failed"; clear(); showPanel()
    setStatus("No transcript received. Check the helper, then press Record to retry.", "error")
end

local function cycleChannel(step)
    local d = settings(); local index = 1
    for i, v in ipairs(CHANNELS) do if v == d.channel then index = i; break end end
    d.channel = CHANNELS[(index - 1 + step) % #CHANNELS + 1]
    updateDestination()
    if not panel:IsShown() then
        print("Local Dictation: channel " .. LABELS[d.channel])
    end
end
function LocalDictation_NextChannel() cycleChannel(1) end
function LocalDictation_PrevChannel() cycleChannel(-1) end

local function cycleTarget(step)
    local list = {}
    for _, e in ipairs(buildEntries("")) do if e.value and e.online then list[#list+1] = e end end
    if #list == 0 then
        setStatus("No online friends or recent whispers to cycle through.", "error")
        if not panel:IsShown() then print("Local Dictation: no online friends to whisper.") end
        return
    end
    local current, index = currentTargetKey(), 0
    if settings().channel == "WHISPER" then
        for i, e in ipairs(list) do if e.key == current then index = i; break end end
    end
    local e
    if index == 0 then e = list[step > 0 and 1 or #list] else e = list[(index - 1 + step) % #list + 1] end
    setWhisperTarget(e.kind, e.value)
    if panel:IsShown() then setStatus("Whisper target: " .. e.label, "info")
    else print("Local Dictation: whisper target " .. e.value) end
end

function LocalDictation_NextTarget() cycleTarget(1) end
function LocalDictation_PrevTarget() cycleTarget(-1) end

function LocalDictation_Friends()
    if not panel:IsShown() then LocalDictation_Toggle() end
    selectChannel("WHISPER")
    openPicker()
end

local function sendChat(text, chatType, target)
    local fn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(fn) ~= "function" then error("This client has no SendChatMessage API.") end
    fn(text, chatType, nil, target)
end

function LocalDictation_Send()
    if not panel:IsShown() then return end
    if state == "recording" or state == "processing" then setStatus("Wait until the transcript is in the preview.", "error"); return end
    local text = trim(cleanMessage(preview:GetText()))
    if text == "" then setStatus("Nothing to send yet.", "error"); return end
    if #text > MAX_BYTES then setStatus("Message exceeds " .. MAX_BYTES .. " bytes. Shorten it before sending.", "error"); return end
    local d = settings()
    local problem = channelProblem(d.channel)
    if problem then setStatus(problem .. " Choose another channel.", "error"); return end
    local ok, err
    if d.channel == "WHISPER" then
        local who = trim(d.target)
        if who == "" then setStatus("Choose a whisper target first.", "error"); openPicker(); return end
        if d.targetKind == "bnet" then
            local id = resolveBNet(who)
            if not id or not BNSendWhisper then setStatus(who .. " is not online on Battle.net.", "error"); return end
            ok, err = pcall(BNSendWhisper, id, text)
        else
            ok, err = pcall(sendChat, text, "WHISPER", who)
        end
    else
        ok, err = pcall(sendChat, text, d.channel)
    end
    if not ok then setStatus("Send failed: " .. tostring(err), "error"); return end
    -- Submitted without a Lua error; the server may still report restrictions in chat.
    LocalDictation_Close()
end

------------------------------------------------------------------------
-- Widget scripts
------------------------------------------------------------------------
close:SetScript("OnClick", LocalDictation_Close)
cancel:SetScript("OnClick", LocalDictation_Close)
send:SetScript("OnClick", LocalDictation_Send)
function LocalDictation_Clear()
    if not panel:IsShown() then return end
    if state == "recording" or state == "processing" then
        setStatus("Wait for the transcript, or press Record to start over.", "error"); return
    end
    clear(); state = "idle"; setStatus("Message cleared.", "idle")
end
clearButton:SetScript("OnClick", LocalDictation_Clear)

panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    settings().position = {point, relPoint, x, y}
end)
------------------------------------------------------------------------
-- Controller navigation while the panel is open (WoW gamepad mode).
-- Temporary override bindings: only while the panel is shown and never in combat.
------------------------------------------------------------------------
local PAD_ACTIONS = {
    Up = function() if picker:IsShown() then movePick(-1) elseif settings().channel == "WHISPER" then cycleTarget(-1) end end,
    Down = function() if picker:IsShown() then movePick(1) elseif settings().channel == "WHISPER" then cycleTarget(1) end end,
    Left = function() if not picker:IsShown() then LocalDictation_PrevChannel() end end,
    Right = function() if not picker:IsShown() then LocalDictation_NextChannel() end end,
    Accept = function() if picker:IsShown() then choosePick() else LocalDictation_Send() end end,
    Back = function() if picker:IsShown() then picker:Hide() else LocalDictation_Close() end end,
    Friends = function() if picker:IsShown() then picker:Hide() else LocalDictation_Friends() end end,
    Clear = function() if not picker:IsShown() then LocalDictation_Clear() end end,
}
local PAD_KEYS = {PADDUP="Up", PADDDOWN="Down", PADDLEFT="Left", PADDRIGHT="Right", PAD1="Accept", PAD2="Back", PAD3="Clear", PAD4="Friends"}
for name, fn in pairs(PAD_ACTIONS) do
    local b = CreateFrame("Button", "LocalDictationPad" .. name, UIParent)
    b:Hide()
    b:RegisterForClicks("AnyUp", "AnyDown")
    local last = 0
    b:SetScript("OnClick", function(_, _, down)
        if down == false then return end
        local now = GetTime()
        if now - last < 0.25 then return end -- press + release reported as two clicks
        last = now
        fn()
    end)
end
local padOwner = CreateFrame("Frame")
local padActive = false
local function gamepadEnabled() return gamepadCVar("GamePadEnable") == "1" end
local function updateHint()
    if padActive then
        hint:SetText(picker:IsShown() and "Controller: D-pad up/down choose  |  A pick  |  B back  |  Y close list"
            or "Pad: left/right channel | up/down target | A send | B close | X clear | Y friends")
    else
        hint:SetText("Enter sends  |  Esc closes  |  Record / Send: your helper keys or buttons")
    end
end
local function applyPad(allow)
    if InCombatLockdown() then return end
    ClearOverrideBindings(padOwner)
    padActive = false
    if allow ~= false and panel:IsShown() and settings().padNav ~= false then
        for key, name in pairs(PAD_KEYS) do SetOverrideBindingClick(padOwner, true, key, "LocalDictationPad" .. name) end
        padActive = gamepadEnabled() or settings().padNav == true
    end
    updateHint()
end
-- Escape closes every frame in UISpecialFrames at once, so while the friend list is open
-- only the list is registered there; the panel is registered again when the list closes.
local function setSpecialFrame(name, on)
    for i = #UISpecialFrames, 1, -1 do if UISpecialFrames[i] == name then table.remove(UISpecialFrames, i) end end
    if on then tinsert(UISpecialFrames, name) end
end
picker:HookScript("OnShow", function()
    setSpecialFrame("LocalDictationPanel", false); setSpecialFrame("LocalDictationFriendPicker", true); updateHint()
end)
picker:HookScript("OnHide", function()
    setSpecialFrame("LocalDictationFriendPicker", false); setSpecialFrame("LocalDictationPanel", true); updateHint()
end)

panel:SetScript("OnShow", function() applyPad() end)
panel:SetScript("OnHide", function() picker:Hide(); stopCapture(); state = "idle"; applyPad() end)

preview:SetScript("OnEscapePressed", LocalDictation_Close)
preview:SetScript("OnEnterPressed", LocalDictation_Send)
preview:SetScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    local clean = cleanMessage(text)
    if clean ~= text then
        local cursor = self:GetCursorPosition()
        self:SetText(clean) -- runs this handler again with the clean text
        self:SetCursorPosition(math.max(0, math.min(#clean, cursor - (#text - #clean))))
        return
    end
    updateCount()
    if (state == "receiving" or state == "idle" or state == "failed") and #text > 0 then
        state = "preview"
        setStatus("Review the text and destination, then press Send (Enter or your Send button).", "ready")
    elseif state == "preview" and #text == 0 then
        state = "idle"
    end
end)

target:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
target:SetScript("OnEnterPressed", function(self) self:ClearFocus(); preview:SetFocus() end)
target:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local d = settings()
    d.target = self:GetText(); d.targetKind = "char"
    targetKind:SetText(d.target ~= "" and "Character whisper" or "Type Name or Name-Realm")
    if picker:IsShown() then refreshPicker() end
end)

-- A focused edit box swallows bindings. Handle the helper's keys and this addon's
-- own hotkeys here so they keep working while typing.
local ACTION_FUNCTIONS = {
    LOCALDICTATION_RECORD=function() LocalDictation_RecordPressed() end,
    LOCALDICTATION_TOGGLE=function() LocalDictation_Toggle() end,
    LOCALDICTATION_CLEAR=function() LocalDictation_Clear() end,
    LOCALDICTATION_SEND=function() LocalDictation_Send() end,
    LOCALDICTATION_NEXT=function() LocalDictation_NextChannel() end,
    LOCALDICTATION_PREV=function() LocalDictation_PrevChannel() end,
    LOCALDICTATION_NEXTTARGET=function() LocalDictation_NextTarget() end,
    LOCALDICTATION_FRIENDS=function() LocalDictation_Friends() end,
    LOCALDICTATION_CLOSE=function() LocalDictation_Close() end,
}
local TYPING_KEYS = {SPACE=true, BACKSPACE=true, DELETE=true, ENTER=true, TAB=true, LEFT=true, RIGHT=true, UP=true, DOWN=true, HOME=true, END=true, ESCAPE=true}
local function editKey(_, key)
    if IsControlKeyDown() and IsShiftKeyDown() and HELPER_SIGNALS[key] then
        local signal = HELPER_SIGNALS[key]
        if signal == "RECORDING" then LocalDictation_Recording()
        elseif signal == "PROCESSING" then LocalDictation_Processing()
        elseif signal == "PREPARE" then LocalDictation_Prepare()
        elseif signal == "SEND" then LocalDictation_Send()
        else LocalDictation_Failed() end
        return
    end
    if IGNORED_KEYS[key] then return end
    local full = chord(key)
    -- Plain printable keys and editing keys are text input, not hotkeys.
    if full == key and (#key == 1 or TYPING_KEYS[key]) then return end
    if full == "SHIFT-" .. key and #key == 1 then return end
    local action = GetBindingAction(full)
    local fn = action and ACTION_FUNCTIONS[action]
    if fn then fn() end
end
preview:SetScript("OnKeyDown", editKey)
target:SetScript("OnKeyDown", editKey)

------------------------------------------------------------------------
-- Events, helper override bindings, slash commands
------------------------------------------------------------------------
local bindingOwner = CreateFrame("Frame")
local function helperBindings()
    if InCombatLockdown() then return end
    ClearOverrideBindings(bindingOwner)
    for key, signal in pairs(HELPER_SIGNALS) do
        for _, prefix in ipairs(SIGNAL_PREFIXES) do
            SetOverrideBinding(bindingOwner, true, prefix .. key, "LOCALDICTATION_" .. signal)
        end
    end
end

local events = CreateFrame("Frame")
local function register(event) pcall(events.RegisterEvent, events, event) end
for _, e in ipairs({"ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "UPDATE_BINDINGS", "PLAYER_LOGOUT", "PLAYER_REGEN_DISABLED"}) do register(e) end
events:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then db = nil; exportedAtLogin = helperSignature(settings()) end
    elseif event == "PLAYER_LOGIN" then
        local p = settings().position
        if type(p) == "table" and p[1] then panel:ClearAllPoints(); panel:SetPoint(p[1], UIParent, p[2], p[3], p[4]) end
        helperBindings()
        exportHelperKeys()
    elseif event == "PLAYER_LOGOUT" then
        exportHelperKeys()
    elseif event == "PLAYER_REGEN_DISABLED" then
        applyPad(false) -- fires just before combat lockdown: give the D-pad and A/B/Y back to the game
    elseif event == "PLAYER_REGEN_ENABLED" then
        helperBindings()
        applyPad()
    elseif event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_WHISPER_INFORM" then
        local _, who = ...
        addRecent(who)
        if picker:IsShown() then refreshPicker() end
    elseif event == "UPDATE_BINDINGS" then
        if keysFrame:IsShown() then refreshKeys() end
        if exportedAtLogin ~= nil then updateReloadHint() end
    elseif panel:IsShown() then
        updateDestination()
    end
end)

-- Candidate Record / Send keys: modifier combos (never typed into chat) and spare keys.
local FREE_KEY_CANDIDATES = {
    "ALT-R", "ALT-S", "ALT-T", "ALT-D", "ALT-F", "ALT-G", "ALT-V", "ALT-X", "ALT-`",
    "ALT-SHIFT-R", "ALT-SHIFT-S", "ALT-SHIFT-D", "ALT-SHIFT-F",
    "CTRL-SHIFT-R", "CTRL-SHIFT-S", "CTRL-SHIFT-D", "CTRL-SHIFT-F", "CTRL-SHIFT-V",
    "ALT-CTRL-R", "ALT-CTRL-S", "ALT-CTRL-D",
    "F11", "F12", "ALT-F11", "ALT-F12",
    "NUMPADDIVIDE", "NUMPADMULTIPLY", "NUMPADMINUS", "NUMPADPLUS",
}
local PAD_NAMES = {PAD1="A", PAD2="B", PAD3="X", PAD4="Y", PADLSHOULDER="L1", PADRSHOULDER="R1", PADLTRIGGER="L2",
    PADRTRIGGER="R2", PADLSTICK="L3", PADRSTICK="R3", PADDUP="D-up", PADDDOWN="D-down", PADDLEFT="D-left", PADDRIGHT="D-right",
    PADFORWARD="Menu", PADBACK="View"}
local function bindingName(action) return _G["BINDING_NAME_" .. action] or action end
-- WoW falls back to the plain key when a modified combo is unbound (that's why Shift+W still walks),
-- so a combo is only "clean" if the plain key does nothing either.
local function baseKey(key) return (key:gsub("^ALT%-", ""):gsub("^CTRL%-", ""):gsub("^SHIFT%-", ""):gsub("^META%-", "")) end
local function classify(candidates, label)
    local clean, risky, ours, taken = {}, {}, {}, {}
    for _, key in ipairs(candidates) do
        local shown = label and label(key) or key
        local action = GetBindingAction(key, true) or ""
        if action:find("^LOCALDICTATION_") then ours[#ours+1] = shown .. " (" .. bindingName(action) .. ")"
        elseif action ~= "" then taken[#taken+1] = shown .. "=" .. bindingName(action)
        else
            local base = baseKey(key)
            local baseAction = base ~= key and GetBindingAction(base, true) or ""
            if baseAction ~= "" and not baseAction:find("^LOCALDICTATION_") then
                risky[#risky+1] = shown .. " (plain " .. (label and label(base) or base) .. " = " .. bindingName(baseAction) .. ")"
            else clean[#clean+1] = shown end
        end
    end
    return clean, risky, ours, taken
end
local function printLists(title, clean, risky, ours, taken)
    print("|cff40ff40" .. title .. " - free:|r " .. (#clean > 0 and table.concat(clean, ", ") or "none of the candidates"))
    if #risky > 0 then print("|cffffd100Free, but the plain key has an action (may fire with it):|r " .. table.concat(risky, ", ")) end
    if #ours > 0 then print("|cff80c0ffAlready Local Dictation:|r " .. table.concat(ours, ", ")) end
    if #taken > 0 then print("|cffaaaaaaTaken:|r " .. table.concat(taken, ", ")) end
end
local function listFreeKeys()
    printLists("Local Dictation keyboard keys", classify(FREE_KEY_CANDIDATES))
    -- Controller combos: WoW's SHIFT/CTRL/ALT on a gamepad are the buttons in the GamePadEmulate* settings.
    local mods = {}
    for mod, cvar in pairs({SHIFT="GamePadEmulateShift", CTRL="GamePadEmulateCtrl", ALT="GamePadEmulateAlt"}) do
        local button = gamepadCVar(cvar)
        if PAD_NAMES[button] then mods[#mods+1] = {mod, PAD_NAMES[button]} end
    end
    if #mods > 0 then
        local pads, names = {}, {}
        for _, m in ipairs(mods) do
            for _, b in ipairs({"PAD1", "PAD2", "PAD3", "PAD4", "PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT", "PADRSHOULDER", "PADRTRIGGER", "PADLSTICK", "PADRSTICK"}) do
                local key = m[1] .. "-" .. b
                pads[#pads+1] = key; names[key] = m[2] .. "+" .. PAD_NAMES[b]; names[b] = PAD_NAMES[b]
            end
        end
        printLists("Controller combos", classify(pads, function(k) return names[k] or PAD_NAMES[k] or k end))
    end
    print("Set one with /ld keys (it accepts controller buttons), then /reload if it is Record / Stop.")
end

SLASH_LOCALDICTATION1 = "/ld"
SlashCmdList.LOCALDICTATION = function(input)
    local command, arg = (input or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()
    if command == "channel" then
        local wanted = arg:upper(); if wanted == "INSTANCE" then wanted = "INSTANCE_CHAT" end
        if LABELS[wanted] then settings().channel = wanted; updateDestination()
        else print("Local Dictation: /ld channel say|party|raid|instance|guild|whisper") end
    elseif command == "whisper" then setWhisperTarget("char", trim(arg))
    elseif command == "friends" then LocalDictation_Friends()
    elseif command == "keys" or command == "hotkeys" then if not panel:IsShown() then LocalDictation_Toggle() end; showKeys(true)
    elseif command == "freekeys" then listFreeKeys()
    elseif command == "pad" then
        local a = arg:lower()
        if a == "off" then settings().padNav = false elseif a == "on" then settings().padNav = true else settings().padNav = nil end
        applyPad()
        print("Local Dictation: controller navigation " .. (settings().padNav == false and "off" or "on") .. " while the panel is open (/ld pad on|off|auto)")
    elseif command == "close" then LocalDictation_Close()
    elseif command == "recording" then LocalDictation_Recording()
    elseif command == "processing" then LocalDictation_Processing()
    elseif command == "status" then
        local d = settings()
        print("Local Dictation: state=" .. state .. ", channel=" .. d.channel .. ", target=" .. d.target .. " (" .. d.targetKind .. ")")
    elseif command == "help" then
        print("Local Dictation: /ld (open), /ld channel <name>, /ld whisper <Name-Realm>, /ld friends, /ld keys, /ld freekeys, /ld pad on|off, /ld status, /ld close")
    else
        if not panel:IsShown() then LocalDictation_Toggle() end
        preview:SetFocus()
    end
end

panel:Hide()
