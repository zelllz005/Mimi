--[[
	Mimi[1.0.0.0]
	Pixel texture pack for Roblox executors. Every block in the map gets chunky pixels;
	players, NPCs and their gear are never touched.

	Open the menu with the round "M" button (drag it anywhere) or press RightShift.
	Needs an executor that supports writefile + getcustomasset.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local NAME = "Mimi[1.0.0.0]"
local TAG = "MimiPixel"
local SMOOTH = Enum.Material.SmoothPlastic
local RESCAN_EVERY = 10 -- seconds between automatic sweeps
local STYLES = { "Classic", "Speckle", "Grain" }

local env = (getgenv and getgenv()) or _G
if env.MimiStop then pcall(env.MimiStop) end
if env.PixelPackStop then pcall(env.PixelPackStop) end -- remove the first version if it is still loaded

local CFG = {
	On = false,
	Flat = false,
	Auto = true,
	PixelSize = 0.5, -- studs per pixel
	Strength = 0.8,
	Style = "Classic",
}

------------------------------------------------------------------ pixel tiles
-- The tile is a tiny PNG the script builds itself: a 16x16 grid of dark / light / empty squares
-- that sits on top of each block, so the block keeps its own colour and only gains pixels.

local GRID, CELL = 16, 4 -- 16x16 pixels per tile, 4 texels per pixel keeps the edges sharp
local SIZE = GRID * CELL

local crcTable = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(0xEDB88320, bit32.rshift(c, 1))
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[i] = c
end

local function crc32(s)
	local c = 0xFFFFFFFF
	for i = 1, #s do
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, s:byte(i)), 255)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function u32(n)
	return string.char(bit32.rshift(n, 24) % 256, bit32.rshift(n, 16) % 256, bit32.rshift(n, 8) % 256, n % 256)
end

local function pngChunk(kind, data)
	return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

-- bias > 0: bright block, favour dark squares. bias < 0: dark block, favour light squares.
local function pixelCell(style, rng, row, bias)
	local pDark, pLight = 0.35, 0.35
	if bias > 0 then
		pDark, pLight = 0.65, 0.1
	elseif bias < 0 then
		pDark, pLight = 0.1, 0.65
	end
	if style == "Speckle" then
		pDark, pLight = pDark * 0.4, pLight * 0.4
	end
	if style == "Grain" and row % 4 == 0 then
		if bias < 0 then return 255, 255, 255, 95 end
		return 0, 0, 0, 125
	end
	local weight = style == "Grain" and 0.4 or 1
	local roll = rng:NextNumber()
	if roll < pDark then
		return 0, 0, 0, math.floor(rng:NextInteger(60, 150) * weight)
	elseif roll < pDark + pLight then
		return 255, 255, 255, math.floor(rng:NextInteger(50, 120) * weight)
	end
	return 128, 128, 128, 0
end

local function buildPNG(style, bias)
	local rng = Random.new(1337 + bias * 31 + #style)
	local lines = {}
	for row = 0, GRID - 1 do
		local line = { "\0" } -- PNG filter byte
		for _ = 0, GRID - 1 do
			line[#line + 1] = string.rep(string.char(pixelCell(style, rng, row, bias)), CELL)
		end
		lines[#lines + 1] = string.rep(table.concat(line), CELL)
	end
	local data = table.concat(lines)

	local a, b = 1, 0
	for i = 1, #data do
		a = (a + data:byte(i)) % 65521
		b = (b + a) % 65521
	end
	local len = #data
	local nlen = 65535 - len
	local zlib = "\120\1"
		.. string.char(1, len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256))
		.. data
		.. u32(b * 65536 + a)

	return "\137PNG\r\n\26\n"
		.. pngChunk("IHDR", u32(SIZE) .. u32(SIZE) .. "\8\6\0\0\0")
		.. pngChunk("IDAT", zlib)
		.. pngChunk("IEND", "")
end

local SUPPORTED = type(writefile) == "function"
	and (type(getcustomasset) == "function" or type(getsynasset) == "function")

local tiles = {}
local function tileFor(style, bias)
	local key = style .. bias
	if tiles[key] == nil then
		local file = ("Mimi_%s_%d.png"):format(style, bias)
		local ok, asset = pcall(function()
			writefile(file, buildPNG(style, bias))
			return (getcustomasset or getsynasset)(file)
		end)
		tiles[key] = ok and asset or false
	end
	return tiles[key]
end

------------------------------------------------------------------ block handling
local statusLabel
local function setStatus(message)
	if statusLabel then statusLabel.Text = message end
end

local FACES = Enum.NormalId:GetEnumItems()
local HAS_ZINDEX = pcall(function() return Instance.new("Texture").ZIndex end)

local function weakKeys() return setmetatable({}, { __mode = "k" }) end
local recs, list, count = weakKeys(), {}, 0 -- part -> record, ordered records, number of blocks
local watcher, scanToken = nil, 0

local function isCharacterOrGear(node)
	if node:IsA("Accessory") or node:IsA("Tool") or node:IsA("Camera") then return true end
	if node:FindFirstChildOfClass("Humanoid") then return true end
	return node:IsA("Model") and Players:GetPlayerFromCharacter(node) ~= nil
end

local function isBlock(part)
	if not part:IsA("BasePart") or part:IsA("Terrain") then return false end
	if part.Transparency > 0.6 or part.Size.Magnitude < 0.3 then return false end
	local node = part.Parent
	while node and node ~= workspace do
		if isCharacterOrGear(node) then return false end
		node = node.Parent
	end
	return node == workspace
end

local function biasOf(color)
	local luma = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
	if luma > 0.65 then return 1 end
	if luma < 0.3 then return -1 end
	return 0
end

local function flatten(rec)
	if not rec.mat and rec.part.Material ~= SMOOTH then
		rec.mat = rec.part.Material
		rec.part.Material = SMOOTH
	end
end

local function unflatten(rec)
	if rec.mat then
		rec.part.Material = rec.mat
		rec.mat = nil
	end
end

local function applyPart(part, force)
	if not CFG.On then return end
	local rec = recs[part]
	if rec and not force then return end
	if not rec and not isBlock(part) then return end

	if rec then
		for _, tex in ipairs(rec.tex) do tex:Destroy() end
		rec.tex = {}
	else
		rec = { part = part, bias = biasOf(part.Color), tex = {} }
		recs[part] = rec
		list[#list + 1] = rec
		count += 1
	end

	local asset = tileFor(CFG.Style, rec.bias)
	if not asset then return end
	for _, face in ipairs(FACES) do
		local tex = Instance.new("Texture")
		tex.Name = TAG
		tex.Face = face
		tex.Texture = asset
		tex.StudsPerTileU = CFG.PixelSize * GRID
		tex.StudsPerTileV = CFG.PixelSize * GRID
		tex.Transparency = 1 - CFG.Strength
		if HAS_ZINDEX then tex.ZIndex = 10 end -- draw above any decals the game already put on the face
		tex.Parent = part
		rec.tex[#rec.tex + 1] = tex
	end
	if CFG.Flat then flatten(rec) end
end

-- runs `action` over every record without freezing the game
local function eachRecord(action)
	local snapshot = list
	task.spawn(function()
		for i = 1, #snapshot do
			action(snapshot[i])
			if i % 250 == 0 then task.wait() end
		end
	end)
end

local function scan(token)
	for i, inst in ipairs(workspace:GetDescendants()) do
		if token ~= scanToken or not CFG.On then return end
		if inst:IsA("BasePart") then
			local rec = recs[inst]
			local first = rec and rec.tex[1]
			if not rec or (first and first.Parent ~= inst) then
				applyPart(inst, rec ~= nil) -- also rebuilds blocks whose textures the game removed
			end
		end
		if i % 150 == 0 then task.wait() end
	end
	setStatus(("%d blocks pixelated"):format(count))
end

local function restyle()
	eachRecord(function(rec)
		local asset = tileFor(CFG.Style, rec.bias)
		for _, tex in ipairs(rec.tex) do
			if asset then tex.Texture = asset end
			tex.StudsPerTileU = CFG.PixelSize * GRID
			tex.StudsPerTileV = CFG.PixelSize * GRID
			tex.Transparency = 1 - CFG.Strength
		end
	end)
end

local function setFlat(on)
	CFG.Flat = on
	if CFG.On then eachRecord(on and flatten or unflatten) end
end

local function enable()
	if not SUPPORTED then
		setStatus("This executor can't save files (needs writefile + getcustomasset)")
		return false
	end
	if not tileFor(CFG.Style, 0) then
		setStatus("Couldn't create the pixel tile")
		return false
	end
	CFG.On = true
	scanToken += 1
	local mine = scanToken
	watcher = workspace.DescendantAdded:Connect(function(inst)
		if inst:IsA("BasePart") then task.delay(0.25, applyPart, inst) end
	end)
	setStatus("Pixelating...")
	task.spawn(function()
		scan(mine)
		while scanToken == mine do
			task.wait(RESCAN_EVERY)
			if scanToken == mine and CFG.Auto then scan(mine) end
		end
	end)
	return true
end

local function disable()
	CFG.On = false
	scanToken += 1
	if watcher then
		watcher:Disconnect()
		watcher = nil
	end
	local old = list
	recs, list, count = weakKeys(), {}, 0
	for _, rec in ipairs(old) do unflatten(rec) end
	task.spawn(function()
		for i, rec in ipairs(old) do
			for _, tex in ipairs(rec.tex) do tex:Destroy() end
			if i % 200 == 0 then task.wait() end
		end
	end)
	setStatus("Off")
end

------------------------------------------------------------------ interface helpers
local THEME = {
	bg = Color3.fromRGB(17, 15, 29),
	side = Color3.fromRGB(23, 20, 40),
	card = Color3.fromRGB(31, 27, 52),
	off = Color3.fromRGB(62, 57, 92),
	text = Color3.fromRGB(240, 237, 252),
	dim = Color3.fromRGB(150, 145, 184),
	pink = Color3.fromRGB(255, 110, 182),
	purple = Color3.fromRGB(150, 110, 255),
	sky = Color3.fromRGB(110, 205, 255),
	red = Color3.fromRGB(235, 80, 100),
}
local ACCENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0, THEME.pink),
	ColorSequenceKeypoint.new(0.5, THEME.purple),
	ColorSequenceKeypoint.new(1, THEME.sky),
})
local RING = ColorSequence.new({
	ColorSequenceKeypoint.new(0, THEME.pink),
	ColorSequenceKeypoint.new(0.33, THEME.purple),
	ColorSequenceKeypoint.new(0.66, THEME.sky),
	ColorSequenceKeypoint.new(1, THEME.pink),
})
local WHITE = Color3.new(1, 1, 1)

local connections = {}
local function bind(signal, handler)
	connections[#connections + 1] = signal:Connect(handler)
end

local function create(class, props, parent)
	local obj = Instance.new(class)
	for key, value in pairs(props) do obj[key] = value end
	obj.Parent = parent
	return obj
end

local function corner(obj, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) }, obj)
end

local function tween(obj, seconds, props, style)
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function text(parent, props)
	props.BackgroundTransparency = 1
	props.TextColor3 = props.TextColor3 or THEME.text
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextSize = props.TextSize or 13
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props, parent)
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- drag `target` by grabbing `handle`; a press that barely moves counts as a tap
local function makeDraggable(handle, target, onTap)
	local dragging, moved, grab, startPos, startInput = false, false, nil, nil, nil
	bind(handle.InputBegan, function(input)
		if isPress(input) then
			dragging, moved, grab = true, false, input
			startPos, startInput = target.Position, input.Position
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseMovement) then
			local delta = input.Position - startInput
			if delta.Magnitude > 6 then moved = true end
			if moved then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			if onTap and not moved then onTap() end
		end
	end)
end

local order = 0
local function card(page, height)
	order += 1
	local frame = create("Frame", { Size = UDim2.new(1, 0, 0, height), BackgroundColor3 = THEME.card, LayoutOrder = order }, page)
	corner(frame, 10)
	return frame
end

local function addToggle(page, title, description, default, onChange)
	local row = card(page, 48)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -80, 0, 18), Font = Enum.Font.GothamBold })
	text(row, { Text = description, Position = UDim2.new(0, 12, 0, 25), Size = UDim2.new(1, -80, 0, 16), TextSize = 11, TextColor3 = THEME.dim })

	local switch = create("TextButton", {
		Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(44, 22), BackgroundColor3 = default and THEME.pink or THEME.off,
	}, row)
	corner(switch, 11)
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE,
		Position = default and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
	}, switch)
	corner(knob, 8)

	local state = default
	switch.Activated:Connect(function()
		local wanted = not state
		if onChange(wanted) == false then return end -- refused (for example, unsupported executor)
		state = wanted
		tween(switch, 0.18, { BackgroundColor3 = state and THEME.pink or THEME.off })
		tween(knob, 0.2, { Position = state and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	end)
end

local function addSlider(page, title, min, max, step, default, format, onCommit)
	local row = card(page, 58)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(0.5, 0, 0, 18), Font = Enum.Font.GothamBold })
	local readout = text(row, {
		Text = format(default), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(0.5, -12, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = THEME.pink, Font = Enum.Font.GothamBold,
	})
	local track = create("Frame", { Position = UDim2.new(0, 12, 0, 38), Size = UDim2.new(1, -24, 0, 6), BackgroundColor3 = THEME.off }, row)
	corner(track, 3)
	local fill = create("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE }, track)
	corner(fill, 3)
	create("UIGradient", { Color = ACCENT }, fill)
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = WHITE, ZIndex = 2,
	}, track)
	corner(knob, 8)
	create("UIStroke", { Color = THEME.purple, Thickness = 2 }, knob)
	local hitbox = create("TextButton", {
		Text = "", BackgroundTransparency = 1, Position = UDim2.new(0, -10, 0, -14), Size = UDim2.new(1, 20, 0, 34), ZIndex = 3,
	}, track)

	local value = default
	local function setFraction(fraction)
		fraction = math.clamp(fraction, 0, 1)
		value = math.clamp(math.floor((min + (max - min) * fraction) / step + 0.5) * step, min, max)
		local shown = (value - min) / (max - min)
		fill.Size = UDim2.fromScale(shown, 1)
		knob.Position = UDim2.fromScale(shown, 0.5)
		readout.Text = format(value)
	end
	setFraction((default - min) / (max - min))

	local dragging, grab = false, nil
	local function follow(input)
		setFraction((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
	end
	bind(hitbox.InputBegan, function(input)
		if isPress(input) then
			dragging, grab = true, input
			page.ScrollingEnabled = false -- keep the page from scrolling while the slider moves
			follow(input)
		end
	end)
	bind(UserInputService.InputChanged, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseMovement) then
			follow(input)
		end
	end)
	bind(UserInputService.InputEnded, function(input)
		if dragging and (input == grab or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			page.ScrollingEnabled = true
			onCommit(value) -- apply once on release so big maps aren't updated every frame
		end
	end)
end

local function addChoice(page, title, options, default, onChange)
	local row = card(page, 68)
	text(row, { Text = title, Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -24, 0, 18), Font = Enum.Font.GothamBold })
	local strip = create("Frame", { Position = UDim2.new(0, 12, 0, 32), Size = UDim2.new(1, -24, 0, 28), BackgroundTransparency = 1 }, row)
	create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	}, strip)

	local buttons, total = {}, #options
	local function highlight(selected)
		for name, button in pairs(buttons) do
			tween(button, 0.18, { BackgroundColor3 = name == selected and THEME.purple or THEME.off })
		end
	end
	for index, name in ipairs(options) do
		local button = create("TextButton", {
			Text = name, AutoButtonColor = false, LayoutOrder = index, TextColor3 = THEME.text,
			Font = Enum.Font.GothamBold, TextSize = 12,
			Size = UDim2.new(1 / total, -math.ceil(6 * (total - 1) / total), 1, 0),
			BackgroundColor3 = name == default and THEME.purple or THEME.off,
		}, strip)
		corner(button, 8)
		button.Activated:Connect(function()
			highlight(name)
			onChange(name)
		end)
		buttons[name] = button
	end
end

local function addButton(page, caption, color, onClick)
	order += 1
	local button = create("TextButton", {
		Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = order,
		BackgroundColor3 = color or WHITE,
	}, page)
	corner(button, 10)
	if not color then create("UIGradient", { Color = ACCENT }, button) end
	text(button, {
		Text = caption, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
		Font = Enum.Font.GothamBold, TextColor3 = WHITE,
	})
	button.Activated:Connect(function()
		button.BackgroundTransparency = 0.4
		tween(button, 0.25, { BackgroundTransparency = 0 })
		onClick()
	end)
end

------------------------------------------------------------------ window
local gui = create("ScreenGui", { Name = "MimiUI", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999 })
if not pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end) or not gui.Parent then
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 400)
local WIDTH = math.clamp(viewport.X - 40, 300, 440)
local HEIGHT = math.clamp(viewport.Y - 40, 210, 270)

local shell = create("Frame", {
	Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(WIDTH, HEIGHT), BackgroundColor3 = THEME.bg, ClipsDescendants = true, Visible = false,
}, gui)
corner(shell, 14)
local ring = create("UIStroke", { Thickness = 2, Color = WHITE }, shell)
local ringGradient = create("UIGradient", { Color = RING }, ring)

-- header
local header = create("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Active = true }, shell)
local title = text(header, {
	Text = NAME, Position = UDim2.new(0, 16, 0, 0), Size = UDim2.new(1, -70, 1, 0),
	Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = WHITE,
})
local titleGradient = create("UIGradient", { Color = ACCENT }, title)
local closeButton = create("TextButton", {
	Text = "X", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
	Size = UDim2.fromOffset(26, 26), BackgroundColor3 = THEME.card, TextColor3 = THEME.dim,
	Font = Enum.Font.GothamBold, TextSize = 13,
}, header)
corner(closeButton, 8)

-- sidebar
local TAB_NAMES = { "Home", "Pixels", "About" }
local side = create("Frame", { Position = UDim2.new(0, 8, 0, 44), Size = UDim2.new(0, 88, 1, -52), BackgroundColor3 = THEME.side }, shell)
corner(side, 10)
local pill = create("Frame", { Position = UDim2.new(0, 6, 0, 8), Size = UDim2.new(1, -12, 0, 34), BackgroundColor3 = WHITE }, side)
corner(pill, 8)
create("UIGradient", { Color = ACCENT, Rotation = 20 }, pill)

-- pages
local body = create("Frame", { Position = UDim2.new(0, 104, 0, 44), Size = UDim2.new(1, -112, 1, -52), BackgroundTransparency = 1 }, shell)
local function newPage()
	local page = create("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
		ScrollBarThickness = 3, ScrollBarImageColor3 = THEME.purple, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, body)
	create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	create("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 4) }, page)
	return page
end
local home, pixels, about = newPage(), newPage(), newPage()

local function unload()
	disable()
	for _, connection in ipairs(connections) do connection:Disconnect() end
	gui:Destroy()
	env.MimiStop = nil
end

-- Home
addToggle(home, "Pixelate Blocks", "Turns every map block into pixels", false, function(on)
	if on then return enable() end
	disable()
end)
addToggle(home, "Flat Materials", "Hides material shine so pixels pop", false, setFlat)
addToggle(home, "Auto Rescan", "Re-checks the map every few seconds", true, function(on)
	CFG.Auto = on
end)
addButton(home, "Rescan Now", nil, function()
	if CFG.On then task.spawn(scan, scanToken) end
end)
local statusCard = card(home, 44)
statusLabel = text(statusCard, {
	Text = "Off", Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -24, 1, 0),
	TextWrapped = true, TextSize = 12, TextColor3 = THEME.dim,
})

-- Pixels
addSlider(pixels, "Pixel Size", 0.125, 3, 0.125, CFG.PixelSize, function(v)
	return ("%g studs"):format(v)
end, function(v)
	CFG.PixelSize = v
	restyle()
end)
addSlider(pixels, "Strength", 0.2, 1, 0.05, CFG.Strength, function(v)
	return ("%d%%"):format(math.floor(v * 100 + 0.5))
end, function(v)
	CFG.Strength = v
	restyle()
end)
addChoice(pixels, "Style", STYLES, CFG.Style, function(name)
	CFG.Style = name
	restyle()
end)

-- About
local infoCard = card(about, 112)
text(infoCard, { Text = NAME, Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 20), Font = Enum.Font.GothamBlack, TextSize = 15 })
text(infoCard, {
	Text = "Pixel texture pack for every block.\nPlayers and NPCs are never touched.\nRoblox terrain can't hold textures.\nMenu key: RightShift",
	Position = UDim2.new(0, 12, 0, 32), Size = UDim2.new(1, -24, 0, 72), TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top, TextSize = 12, TextColor3 = THEME.dim,
})
addButton(about, "Unload Mimi", THEME.red, unload)

-- tabs
local pageOf = { Home = home, Pixels = pixels, About = about }
local tabButtons, currentTab = {}, nil
local function selectTab(name)
	if name == currentTab then return end
	currentTab = name
	for tabName, page in pairs(pageOf) do page.Visible = tabName == name end
	tween(pill, 0.25, { Position = UDim2.new(0, 6, 0, 8 + (table.find(TAB_NAMES, name) - 1) * 40) }, Enum.EasingStyle.Back)
	for tabName, button in pairs(tabButtons) do
		tween(button, 0.2, { TextColor3 = tabName == name and WHITE or THEME.dim })
	end
	local page = pageOf[name]
	page.Position = UDim2.fromOffset(16, 0)
	tween(page, 0.25, { Position = UDim2.new() })
end
for index, name in ipairs(TAB_NAMES) do
	local button = create("TextButton", {
		Text = name, BackgroundTransparency = 1, AutoButtonColor = false, ZIndex = 2,
		Position = UDim2.new(0, 6, 0, 8 + (index - 1) * 40), Size = UDim2.new(1, -12, 0, 34),
		Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = THEME.dim,
	}, side)
	button.Activated:Connect(function() selectTab(name) end)
	tabButtons[name] = button
end
selectTab("Home")

-- open / close
local isOpen = false
local fullSize = UDim2.fromOffset(WIDTH, HEIGHT)
local smallSize = UDim2.fromOffset(WIDTH * 0.92, HEIGHT * 0.92)
local function setOpen(open)
	isOpen = open
	if open then
		shell.Visible = true
		shell.BackgroundTransparency = 1
		ring.Transparency = 1
		shell.Size = smallSize
		tween(shell, 0.3, { Size = fullSize }, Enum.EasingStyle.Back)
		tween(shell, 0.2, { BackgroundTransparency = 0 })
		tween(ring, 0.2, { Transparency = 0 })
	else
		tween(shell, 0.18, { Size = smallSize, BackgroundTransparency = 1 })
		tween(ring, 0.18, { Transparency = 1 }).Completed:Connect(function()
			if not isOpen then shell.Visible = false end
		end)
	end
end
closeButton.Activated:Connect(function() setOpen(false) end)
makeDraggable(header, shell)

-- small movable opener button
local opener = create("TextButton", {
	Name = "Opener", Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(44, 44),
	Position = UDim2.new(0, 14, 0.42, 0), BackgroundColor3 = WHITE,
}, gui)
corner(opener, 12)
local openerGradient = create("UIGradient", { Color = RING }, opener)
local openerStroke = create("UIStroke", { Color = WHITE, Thickness = 2, Transparency = 0.7 }, opener)
text(opener, {
	Text = "M", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBlack, TextSize = 22, TextColor3 = WHITE,
})
TweenService:Create(
	openerStroke,
	TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Transparency = 0.1 }
):Play()
makeDraggable(opener, opener, function() setOpen(not isOpen) end)

bind(UserInputService.InputBegan, function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.RightShift then setOpen(not isOpen) end
end)

-- animated colours
bind(RunService.Heartbeat, function()
	local now = os.clock()
	openerGradient.Rotation = (now * 80) % 360
	if shell.Visible then
		ringGradient.Rotation = (now * 70) % 360
		titleGradient.Offset = Vector2.new(math.sin(now * 1.6) * 0.35, 0)
	end
end)

env.MimiStop = unload
