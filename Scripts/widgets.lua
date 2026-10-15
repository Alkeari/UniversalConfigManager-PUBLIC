-- The two UMG construction calls this mod needs. StaticConstructObject for a raw UWidget;
-- WidgetBlueprintLibrary:Create for a UserWidget-derived Blueprint (it also runs the widget's own
-- Construct/PreConstruct graph, which buttons and rows depend on). Create() rejects a
-- non-UserWidget class, so the two are not interchangeable.
local log = require("logger")

local Widgets = {}

-- Constructs a raw (non-UserWidget) UMG object, e.g. "/Script/UMG.VerticalBox", under `outer`.
function Widgets.construct(classPath, outer)
    local class = StaticFindObject(classPath)
    if not class or not class:IsValid() or outer == nil or not outer:IsValid() then
        return nil
    end
    local ok, widget = pcall(function()
        return StaticConstructObject(class, outer, 0, 0, 0, nil, false, false, nil)
    end)
    return ok and widget and widget:IsValid() and widget or nil
end

-- Constructs a UserWidget-derived Blueprint widget. `worldContext` must be an already-live widget
-- (the options screen instance); Create silently returns an invalid widget for a freshly
-- constructed one.
function Widgets.createUserWidget(worldContext, classPath, assetPath)
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local class = StaticFindObject(classPath)
    if (not class or not class:IsValid()) and assetPath ~= nil then
        pcall(function() LoadAsset(assetPath) end)
        class = StaticFindObject(classPath)
    end
    if not library or not library:IsValid() then
        log.warn("createUserWidget(" .. classPath .. "): WidgetBlueprintLibrary invalid")
        return nil
    end
    if not class or not class:IsValid() then
        log.warn("createUserWidget(" .. classPath .. "): class not found")
        return nil
    end
    if worldContext == nil or not worldContext:IsValid() then
        log.warn("createUserWidget(" .. classPath .. "): worldContext invalid")
        return nil
    end
    local owner = nil
    pcall(function() owner = worldContext:GetOwningPlayer() end)
    local ok, widget = pcall(function()
        return library:Create(worldContext, class, owner)
    end)
    if not ok then
        log.warn("createUserWidget(" .. classPath .. ") threw: " .. tostring(widget))
        return nil
    end
    if not widget or not widget:IsValid() then
        log.warn("createUserWidget(" .. classPath .. ") returned an invalid widget")
        return nil
    end
    return widget
end

-- Inserts `child` directly after `anchor` in a VerticalBox: pops every trailing sibling,
-- adds the child, re-adds the siblings (PalModOptions' own idiom; UPanelWidget exposes no
-- BlueprintCallable insert-at-index). Each engine call is its own pcall.
function Widgets.insertAfter(panel, anchor, child)
    if panel == nil or anchor == nil or child == nil then
        return nil
    end
    local anchorIndex, count = nil, nil
    pcall(function()
        anchorIndex = panel:GetChildIndex(anchor)
        count = panel:GetChildrenCount()
    end)
    if anchorIndex == nil or anchorIndex < 0 or count == nil then
        return nil
    end
    local trailing = {}
    for index = count - 1, anchorIndex + 1, -1 do
        local sibling = nil
        pcall(function()
            sibling = panel:GetChildAt(index)
            panel:RemoveChildAt(index)
        end)
        if sibling ~= nil then
            table.insert(trailing, 1, sibling)
        end
    end
    local slot = nil
    pcall(function() slot = panel:AddChildToVerticalBox(child) end)
    for _, sibling in ipairs(trailing) do
        pcall(function() panel:AddChildToVerticalBox(sibling) end)
    end
    return slot
end

-- Places `child` in a CanvasPanel with explicit anchors, alignment, position and size.
function Widgets.placeInCanvas(canvas, child, layout)
    if canvas == nil or child == nil or layout == nil then
        return nil
    end
    local slot = nil
    pcall(function() slot = canvas:AddChildToCanvas(child) end)
    if slot == nil then
        return nil
    end
    pcall(function()
        slot:SetAnchors({ Minimum = { X = layout.anchorMinX, Y = layout.anchorMinY },
            Maximum = { X = layout.anchorMaxX, Y = layout.anchorMaxY } })
    end)
    pcall(function() slot:SetAlignment({ X = layout.alignX, Y = layout.alignY }) end)
    pcall(function() slot:SetPosition({ X = layout.x, Y = layout.y }) end)
    pcall(function() slot:SetSize({ X = layout.w, Y = layout.h }) end)
    -- Auto-size last: the slot then reports the child's own desired size, which is what makes a
    -- right or centre alignment offset correctly. Without it an aligned slot sized 0x0 has
    -- nothing to offset by and its content runs off the edge it was anchored to.
    if layout.autoSize then
        pcall(function() slot:SetAutoSize(true) end)
    end
    return slot
end

-- Converts an sRGB color table (Config.ui.theme.colors) to the linear-light FLinearColor the
-- UMG color setters take: feeding sRGB fractions straight in renders visibly dull (the standard
-- sRGB EOTF, IEC 61966-2-1).
function Widgets.linearColor(srgb)
    if srgb == nil then
        return nil
    end
    local function toLinear(c)
        c = c or 0
        if c <= 0.04045 then
            return c / 12.92
        end
        return ((c + 0.055) / 1.055) ^ 2.4
    end
    return { R = toLinear(srgb.R), G = toLinear(srgb.G), B = toLinear(srgb.B), A = srgb.A }
end

return Widgets
