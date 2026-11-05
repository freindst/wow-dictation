local addonName = ...
BINDING_HEADER_LOCALDICTATION = "Local Dictation"
BINDING_NAME_LOCALDICTATION_RECORDING = "Helper: recording started"
BINDING_NAME_LOCALDICTATION_PROCESSING = "Helper: transcription started"
BINDING_NAME_LOCALDICTATION_PREPARE = "Open / focus dictation preview"
BINDING_NAME_LOCALDICTATION_SEND = "Send dictation preview"
BINDING_NAME_LOCALDICTATION_FAILED = "Helper: recording failed"
BINDING_NAME_LOCALDICTATION_NEXT = "Next dictation channel"
BINDING_NAME_LOCALDICTATION_CLOSE = "Cancel / close dictation preview"
local channels = {"SAY", "PARTY", "RAID", "INSTANCE_CHAT", "GUILD", "WHISPER"}
local labels = {SAY="Say", PARTY="Party", RAID="Raid", INSTANCE_CHAT="Instance", GUILD="Guild", WHISPER="Whisper"}
local state = "idle"
local db
local function settings()
    if not db then
        if type(LocalDictationDB) ~= "table" then LocalDictationDB = {} end
        db = LocalDictationDB
        if not labels[db.channel] then db.channel = "PARTY" end
        if type(db.target) ~= "string" then db.target = "" end
    end
    return db
end
local panel = CreateFrame("Frame", "LocalDictationPanel", UIParent, "BackdropTemplate")
panel:SetSize(590, 380)
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background", edgeFile="Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=16, insets={left=4,right=4,top=4,bottom=4}})
panel:SetBackdropColor(0.04,0.05,0.08,0.98)
local title = panel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
title:SetPoint("TOPLEFT",20,-20); title:SetText("Local Dictation")
local close = CreateFrame("Button",nil,panel,"UIPanelCloseButton")
close:SetPoint("TOPRIGHT",-5,-5)
local status = panel:CreateFontString(nil,"OVERLAY","GameFontHighlight")
status:SetPoint("TOPLEFT",20,-53); status:SetWidth(550); status:SetJustifyH("LEFT")
local channel = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
channel:SetSize(150,26); channel:SetPoint("TOPLEFT",20,-86)
local targetLabel = panel:CreateFontString(nil,"OVERLAY","GameFontNormal")
targetLabel:SetPoint("LEFT",channel,"RIGHT",14,0); targetLabel:SetText("To:")
local target = CreateFrame("EditBox",nil,panel,"InputBoxTemplate")
target:SetSize(260,26); target:SetPoint("LEFT",targetLabel,"RIGHT",10,0); target:SetAutoFocus(false); target:SetMaxLetters(100)
local previewBG = CreateFrame("Frame",nil,panel,"BackdropTemplate")
previewBG:SetPoint("TOPLEFT",20,-130); previewBG:SetSize(550,160)
previewBG:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
previewBG:SetBackdropColor(0,0,0,0.65)
local scroll = CreateFrame("ScrollFrame",nil,previewBG,"UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT",10,-10); scroll:SetPoint("BOTTOMRIGHT",-28,10)
local preview = CreateFrame("EditBox","LocalDictationPreview",scroll)
preview:SetMultiLine(true); preview:SetAutoFocus(false); preview:SetFontObject(ChatFontNormal); preview:SetWidth(500); preview:SetHeight(140); preview:SetMaxBytes(4096)
scroll:SetScrollChild(preview)
local count = panel:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
count:SetPoint("TOPLEFT",20,-299)
local hint = panel:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT",20,17); hint:SetWidth(390); hint:SetJustifyH("LEFT")
hint:SetText("Record button: start / stop / replace draft.\nSend button: submit preview, clear and close.")
local send = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
send:SetSize(110,28); send:SetPoint("BOTTOMRIGHT",-20,17); send:SetText("Send")
local function updateDestination()
    local d = settings()
    channel:SetText(labels[d.channel] .. "  >")
    targetLabel:SetShown(d.channel == "WHISPER"); target:SetShown(d.channel == "WHISPER")
    if target:GetText() ~= d.target then target:SetText(d.target) end
end
local function clear()
    preview:SetText(""); preview:ClearFocus(); target:ClearFocus(); send:Disable()
end
function LocalDictation_Close()
    state="idle"; clear(); panel:Hide()
end
close:SetScript("OnClick",LocalDictation_Close)
preview:SetScript("OnEscapePressed",LocalDictation_Close)
target:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
target:SetScript("OnEnterPressed",function(self) self:ClearFocus(); preview:SetFocus() end)
target:SetScript("OnTextChanged",function(self) settings().target=self:GetText() end)
preview:SetScript("OnTextChanged",function(self)
    local text=self:GetText() or ""
    count:SetText(#text .. " / 255 bytes")
    if (state=="receiving" or state=="preview") and #text>0 then
        state="preview"; status:SetText("Review the text and destination, then press your Send button.")
        send:Enable()
    else send:Disable() end
end)
function LocalDictation_Recording()
    state="recording"; clear(); updateDestination(); panel:Show()
    status:SetText("Recording... Press your dictation button again to stop.")
end
function LocalDictation_Processing()
    state="processing"; preview:ClearFocus(); send:Disable(); panel:Show()
    status:SetText("Transcribing locally... Waiting for the Mac helper.")
end
function LocalDictation_Prepare()
    state="receiving"; clear(); updateDestination(); panel:Show()
    status:SetText("Opening preview... Waiting for the helper to paste.")
    preview:SetFocus()
end
function LocalDictation_Failed()
    state="failed"; clear(); panel:Show()
    status:SetText("No transcript received. Check the Mac helper, then press Record to retry.")
end
function LocalDictation_NextChannel()
    local d=settings(); local index=1
    for i,v in ipairs(channels) do if v==d.channel then index=i; break end end
    d.channel=channels[index % #channels + 1]
    updateDestination()
end
channel:SetScript("OnClick",LocalDictation_NextChannel)
function LocalDictation_Send()
    if not panel:IsShown() or state~="preview" then return end
    local text=(preview:GetText() or ""):gsub("^%s+",""):gsub("%s+$","")
    if text=="" then return end
    if #text>255 then status:SetText("Message exceeds 255 bytes. Shorten it before sending."); return end
    local d=settings()
    if d.channel=="WHISPER" and d.target:match("^%s*$") then status:SetText("Set a whisper recipient (Name or Name-Realm) first."); target:SetFocus(); return end
    if d.channel=="GUILD" and IsInGuild and not IsInGuild() then status:SetText("You are not in a guild. Choose another channel."); return end
    local fn = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    if type(fn)~="function" then status:SetText("This client has no supported SendChatMessage API."); return end
    local ok,err=pcall(fn,text,d.channel,nil,d.channel=="WHISPER" and d.target or nil)
    if not ok then status:SetText("Send failed: " .. tostring(err)); return end
    -- Submission succeeded without a Lua error; the server may still report restrictions in chat.
    LocalDictation_Close()
end
send:SetScript("OnClick",LocalDictation_Send)
-- A focused edit box can consume bindings. Handle the helper's non-text keys here too.
local function helperKey(_, key)
    if not (IsControlKeyDown() and IsShiftKeyDown()) then return end
    if key=="F13" then LocalDictation_Recording()
    elseif key=="F14" then LocalDictation_Processing()
    elseif key=="F15" then LocalDictation_Prepare()
    elseif key=="F16" then LocalDictation_Send()
    elseif key=="F17" then LocalDictation_Failed() end
end
preview:SetScript("OnKeyDown",helperKey)
target:SetScript("OnKeyDown",helperKey)
local bindingOwner=CreateFrame("Frame")
local function bindings()
    if InCombatLockdown() then return end
    ClearOverrideBindings(bindingOwner)
    SetOverrideBinding(bindingOwner,true,"CTRL-SHIFT-F13","LOCALDICTATION_RECORDING")
    SetOverrideBinding(bindingOwner,true,"CTRL-SHIFT-F14","LOCALDICTATION_PROCESSING")
    SetOverrideBinding(bindingOwner,true,"CTRL-SHIFT-F15","LOCALDICTATION_PREPARE")
    SetOverrideBinding(bindingOwner,true,"CTRL-SHIFT-F16","LOCALDICTATION_SEND")
    SetOverrideBinding(bindingOwner,true,"CTRL-SHIFT-F17","LOCALDICTATION_FAILED")
end
local events=CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN"); events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent",function() settings(); bindings() end)
SLASH_LOCALDICTATION1="/ld"
SlashCmdList.LOCALDICTATION=function(input)
    local command,arg=(input or ""):match("^(%S*)%s*(.-)$")
    command=command:lower()
    if command=="channel" then
        local wanted=arg:upper(); if wanted=="INSTANCE" then wanted="INSTANCE_CHAT" end
        if labels[wanted] then settings().channel=wanted; updateDestination() else print("Local Dictation: /ld channel say|party|raid|instance|guild|whisper") end
    elseif command=="whisper" then settings().channel="WHISPER"; settings().target=arg; updateDestination()
    elseif command=="close" then LocalDictation_Close()
    elseif command=="recording" then LocalDictation_Recording()
    elseif command=="processing" then LocalDictation_Processing()
    elseif command=="status" then print("Local Dictation: state="..state..", channel="..settings().channel..", target="..settings().target)
    else LocalDictation_Prepare() end
end
panel:Hide()
