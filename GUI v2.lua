--[[
    MenuSenseLib v2  -  animated, searchable, draggable-section UI library (Luau / Roblox)

    Elements : Toggle (+keybind), Button (ripple), Dropdown, MultiDropdown, ColorPicker,
               Textbox, Slider, Image, Label, Separator
    Features : * search bar (sidebar) that filters every element, section and tab
               * every section card can be dragged anywhere, even outside the window.
                 Dropping it back over the window returns it to its slot.
               * toast notifications (Window:Notify)
               * staggered tab/section animations, button ripples, hover tweens
               * re-running the script destroys the previous UI and disconnects
                 every connection it made

    Usage:
        local Library = require(path.to.MenuSenseLib)
        local Window  = Library:CreateWindow({ Title = "Menu", TitleAccent = "Sense", Keybind = Enum.KeyCode.RightShift })
        local Tab     = Window:AddTab({ Name = "General", Description = "..." })
        local Section = Tab:AddSection({ Name = "General", Side = "Left" })
        Section:AddToggle({ Name = "Enable", Keybind = Enum.KeyCode.X, Callback = print })

    Window API : :AddTab  :SelectTab  :SetVisible  :ResetLayout  :Notify(text, seconds)
                 :ApplySearch(text)  :ClearSearch  :Unload
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local GLOBAL_KEY = "__MenuSenseLib"
local GUI_NAME = "MenuSenseLib_UI"

-- Remove every trace of a previous run ---------------------------------------
if _G[GLOBAL_KEY] then
	pcall(function() _G[GLOBAL_KEY]:Unload() end)
	_G[GLOBAL_KEY] = nil
end

local Library = {}
Library.Flags = {}

local Theme = {
	Accent = Color3.fromRGB(255, 45, 85),
	Background = Color3.fromRGB(14, 14, 16),
	Sidebar = Color3.fromRGB(18, 18, 21),
	Section = Color3.fromRGB(20, 20, 24),
	Element = Color3.fromRGB(28, 28, 33),
	ElementHover = Color3.fromRGB(38, 38, 45),
	Stroke = Color3.fromRGB(40, 40, 47),
	Text = Color3.fromRGB(235, 235, 240),
	SubText = Color3.fromRGB(140, 140, 150),
}
Library.Theme = Theme

-- Utilities --------------------------------------------------------------------
local connections = {}

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local function new(class, props, children)
	local inst = Instance.new(class)
	for k, v in props do
		if k ~= "Parent" then inst[k] = v end
	end
	if children then
		for _, c in children do c.Parent = inst end
	end
	if props.Parent then inst.Parent = props.Parent end
	return inst
end

local function tween(inst, props, t, style, dir)
	local tw = TweenService:Create(inst, TweenInfo.new(t or 0.18, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function corner(parent, r)
	return new("UICorner", { CornerRadius = UDim.new(0, r), Parent = parent })
end

local function stroke(parent, color, thickness)
	return new("UIStroke", {
		Color = color or Theme.Stroke,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function padding(parent, t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b), PaddingLeft = UDim.new(0, l),
		Parent = parent,
	})
end

local function listLayout(parent, pad, dir)
	return new("UIListLayout", {
		Padding = UDim.new(0, pad or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = dir or Enum.FillDirection.Vertical,
		Parent = parent,
	})
end

local function text(props)
	local base = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do base[k] = v end
	return new("TextLabel", base)
end

local function mouse()
	return UserInputService:GetMouseLocation()
end

local function inside(gui, pos)
	local p, s = gui.AbsolutePosition, gui.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

-- onBegin(mouse) / onMove(mouse) / onEnd(mouse); left mouse button only
local function dragHandler(handle, onBegin, onMove, onEnd)
	local dragging = false
	connect(handle.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			onBegin(mouse())
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			onMove(mouse())
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
			if onEnd then onEnd(mouse()) end
		end
	end)
end

local function titledLine(parent, title)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Parent = parent })
	local l = text({ Text = title, TextSize = 12, TextColor3 = Theme.SubText, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), Parent = f })
	local line = new("Frame", { BackgroundColor3 = Theme.Stroke, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Parent = f })
	local function layout()
		local w = l.TextBounds.X + 8
		line.Position = UDim2.new(0, w, 0.5, 0)
		line.Size = UDim2.new(1, -w, 0, 1)
	end
	layout()
	connect(l:GetPropertyChangedSignal("TextBounds"), layout)
	return f
end

local function keyName(k)
	return k and k.Name or "None"
end

-- Section ------------------------------------------------------------------------
local Section = {}
Section.__index = Section

-- every element registers itself so the search bar can find it
function Section:_register(name, frame, extra)
	local entry = {
		Name = name or "",
		Frame = frame,
		Search = string.lower((name or "") .. " " .. (extra or "")),
	}
	table.insert(self._items, entry)
	return entry
end

function Section:_refreshVisible()
	local show = self._searchVisible ~= false
	if self._floating and self.Window.CurrentTab ~= self.Tab then
		show = false -- floating cards only show on their own tab
	end
	self.Frame.Visible = show
end

function Section:ReturnHome(animate)
	if not self._floating then return end
	self._floating = false
	local f = self.Frame
	f.Parent = self._column
	f.Size = UDim2.new(1, 0, 0, 0)
	f.Position = UDim2.new()
	f.LayoutOrder = self._order
	tween(self._stroke, { Color = Theme.Stroke }, 0.2)
	if animate then
		self._scale.Scale = 0.93
	end
	tween(self._scale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
	self:_refreshVisible()
end

function Section:AddLabel(str, o)
	o = o or {}
	local lbl = text({
		Text = str, TextWrapped = true, TextSize = o.TextSize or 12,
		TextColor3 = o.Color or Theme.SubText,
		Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self.Content,
	})
	self:_register(str, lbl)
	local obj = {}
	function obj:Set(s) lbl.Text = s end
	return obj
end

function Section:AddSeparator(title)
	if title and title ~= "" then
		local f = titledLine(self.Content, title)
		self:_register(title, f)
	else
		local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 8), BackgroundTransparency = 1, Parent = self.Content })
		new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Theme.Stroke, BorderSizePixel = 0, Parent = holder })
		self:_register("", holder)
	end
end

function Section:AddImage(o)
	local img = new("ImageLabel", {
		Size = UDim2.new(1, 0, 0, o.Height or 80),
		BackgroundColor3 = Theme.Element, BorderSizePixel = 0,
		Image = o.Image or "", ScaleType = o.ScaleType or Enum.ScaleType.Fit,
		Parent = self.Content,
	})
	corner(img, 6)
	self:_register(o.Name or "image", img)
	local obj = {}
	function obj:Set(id) img.Image = id end
	return obj
end

function Section:AddButton(o)
	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = Theme.Element,
		Text = o.Name, Font = Enum.Font.GothamMedium, TextSize = 13,
		TextColor3 = Theme.Text, AutoButtonColor = false, ClipsDescendants = true,
		Parent = self.Content,
	})
	corner(btn, 5)
	local st = stroke(btn, Theme.Stroke)
	local sc = new("UIScale", { Parent = btn })
	local hovering = false
	connect(btn.MouseEnter, function()
		hovering = true
		tween(btn, { BackgroundColor3 = Theme.ElementHover }, 0.12)
		tween(st, { Color = Theme.Accent }, 0.12)
	end)
	connect(btn.MouseLeave, function()
		hovering = false
		tween(btn, { BackgroundColor3 = Theme.Element }, 0.12)
		tween(st, { Color = Theme.Stroke }, 0.12)
		tween(sc, { Scale = 1 }, 0.1)
	end)
	connect(btn.MouseButton1Down, function()
		tween(sc, { Scale = 0.97 }, 0.08)
		-- ripple from the click position
		local rel = mouse() - btn.AbsolutePosition
		local r = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(rel.X, rel.Y),
			Size = UDim2.fromOffset(0, 0), BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 0.55, BorderSizePixel = 0, Parent = btn,
		})
		corner(r, 200)
		tween(r, { Size = UDim2.fromOffset(280, 280), BackgroundTransparency = 1 }, 0.55)
		task.delay(0.6, function() r:Destroy() end)
	end)
	connect(btn.MouseButton1Up, function() tween(sc, { Scale = 1 }, 0.1, Enum.EasingStyle.Back) end)
	connect(btn.MouseButton1Click, function()
		btn.BackgroundColor3 = Theme.Accent
		tween(btn, { BackgroundColor3 = hovering and Theme.ElementHover or Theme.Element }, 0.3)
		if o.Callback then task.spawn(o.Callback) end
	end)
	self:_register(o.Name, btn, "button")
	return btn
end

function Section:AddToggle(o)
	local flag = o.Flag or o.Name
	local state = o.Default == true
	local hasBind = o.Keybind ~= nil and o.Keybind ~= false
	local bind = typeof(o.Keybind) == "EnumItem" and o.Keybind or nil
	local listening = false

	local row = new("TextButton", { Name = o.Name, Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = self.Content })
	local box = new("Frame", { Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 0, 0.5, -8), BackgroundColor3 = Theme.Element, BorderSizePixel = 0, Parent = row })
	corner(box, 4)
	local boxStroke = stroke(box, Theme.Stroke)
	local fill = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0, 0), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = box })
	corner(fill, 4)
	local lbl = text({ Text = o.Name, Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -70, 1, 0), TextColor3 = Theme.SubText, Parent = row })

	local keyBtn, keyStroke
	if hasBind then
		keyBtn = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(54, 18),
			BackgroundColor3 = Theme.Element, Font = Enum.Font.GothamMedium, TextSize = 11,
			TextColor3 = Theme.SubText, Text = keyName(bind), AutoButtonColor = false, Parent = row,
		})
		corner(keyBtn, 4)
		keyStroke = stroke(keyBtn, Theme.Stroke)
		Library.Flags[flag .. "_Bind"] = bind
	end

	local function renderBind()
		if not keyBtn then return end
		keyBtn.Text = listening and "..." or keyName(bind)
		tween(keyBtn, { TextColor3 = listening and Theme.Accent or Theme.SubText }, 0.12)
		tween(keyStroke, { Color = listening and Theme.Accent or Theme.Stroke }, 0.12)
		Library.Flags[flag .. "_Bind"] = bind
	end

	local function render()
		tween(fill, { Size = state and UDim2.fromScale(1, 1) or UDim2.fromScale(0, 0) }, 0.2, state and Enum.EasingStyle.Back or Enum.EasingStyle.Quad)
		tween(boxStroke, { Color = state and Theme.Accent or Theme.Stroke }, 0.15)
		tween(lbl, { TextColor3 = state and Theme.Text or Theme.SubText }, 0.15)
	end

	local function set(v, silent)
		state = v and true or false
		Library.Flags[flag] = state
		render()
		if not silent and o.Callback then task.spawn(o.Callback, state) end
	end

	-- hover nudge
	connect(row.MouseEnter, function()
		if not state then tween(lbl, { TextColor3 = Theme.Text }, 0.1) end
		tween(lbl, { Position = UDim2.fromOffset(30, 0) }, 0.12)
	end)
	connect(row.MouseLeave, function()
		if not state then tween(lbl, { TextColor3 = Theme.SubText }, 0.1) end
		tween(lbl, { Position = UDim2.fromOffset(26, 0) }, 0.12)
	end)
	connect(row.MouseButton1Click, function() set(not state) end)

	if keyBtn then
		connect(keyBtn.MouseButton1Click, function()
			listening = true
			renderBind()
		end)
		connect(UserInputService.InputBegan, function(input, processed)
			if listening then
				if input.UserInputType == Enum.UserInputType.Keyboard then
					bind = input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode or nil
					listening = false
					renderBind()
				end
				return
			end
			if processed or not bind then return end
			if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == bind then
				set(not state)
			end
		end)
	end

	Library.Flags[flag] = state
	render()
	renderBind()
	self:_register(o.Name, row, "toggle")

	local obj = {}
	function obj:Set(v, silent) set(v, silent) end
	function obj:Get() return state end
	function obj:SetKeybind(k) bind = k; renderBind() end
	return obj
end

function Section:AddSlider(o)
	local flag = o.Flag or o.Name
	local min, max, inc = o.Min or 0, o.Max or 100, o.Increment or 1
	local suffix = o.Suffix or ""
	local dec = #((tostring(inc):split(".")[2]) or "")
	local value = math.clamp(o.Default or min, min, max)

	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, Parent = self.Content })
	text({ Text = o.Name, Size = UDim2.new(1, -70, 0, 16), TextColor3 = Theme.SubText, Parent = row })
	local valLbl = text({ Size = UDim2.new(0, 70, 0, 16), Position = UDim2.new(1, -70, 0, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = Theme.SubText, TextSize = 12, Parent = row })
	local hit = new("TextButton", { Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = row })
	local track = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = Theme.Element, BorderSizePixel = 0, Parent = hit })
	corner(track, 2)
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = track })
	corner(fill, 2)
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = track })
	corner(knob, 8)

	local function set(v, silent)
		v = math.clamp(math.floor((v - min) / inc + 0.5) * inc + min, min, max)
		v = tonumber(string.format("%." .. dec .. "f", v))
		value = v
		local p = (max == min) and 0 or (v - min) / (max - min)
		tween(fill, { Size = UDim2.fromScale(p, 1) }, 0.08)
		tween(knob, { Position = UDim2.fromScale(p, 0.5) }, 0.08)
		valLbl.Text = tostring(v) .. suffix
		Library.Flags[flag] = v
		if not silent and o.Callback then task.spawn(o.Callback, v) end
	end

	local function fromMouse(m)
		local p = math.clamp((m.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		set(min + p * (max - min))
	end

	dragHandler(hit,
		function(m) tween(knob, { Size = UDim2.fromOffset(14, 14) }, 0.12, Enum.EasingStyle.Back); fromMouse(m) end,
		fromMouse,
		function() tween(knob, { Size = UDim2.fromOffset(10, 10) }, 0.12) end)

	set(value, true)
	self:_register(o.Name, row, "slider")
	local obj = {}
	function obj:Set(v) set(v) end
	function obj:Get() return value end
	return obj
end

local function buildDropdown(self, o, multi)
	local flag = o.Flag or o.Name
	local options = o.Options or {}
	local selected = {}
	local single = nil
	local open = false
	local ITEM_H, GAP, MAX_H = 24, 2, 156
	local buttons = {}

	local container = new("Frame", { Size = UDim2.new(1, 0, 0, 48), BackgroundTransparency = 1, ClipsDescendants = true, Parent = self.Content })
	text({ Text = o.Name, TextSize = 12, TextColor3 = Theme.SubText, Size = UDim2.new(1, 0, 0, 16), Parent = container })
	local head = new("TextButton", { Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Theme.Element, Text = "", AutoButtonColor = false, Parent = container })
	corner(head, 5)
	local headStroke = stroke(head, Theme.Stroke)
	local valueLabel = text({ Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -32, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
	local arrow = text({ Text = "▼", TextSize = 8, TextColor3 = Theme.SubText, Size = UDim2.fromOffset(20, 26), Position = UDim2.new(1, -24, 0, 0), TextXAlignment = Enum.TextXAlignment.Center, Parent = head })

	local list = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = Theme.Element,
		BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Accent,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = container,
	})
	corner(list, 5)
	padding(list, 3, 3, 3, 3)
	listLayout(list, GAP)

	connect(head.MouseEnter, function() if not open then tween(head, { BackgroundColor3 = Theme.ElementHover }, 0.12) end end)
	connect(head.MouseLeave, function() tween(head, { BackgroundColor3 = Theme.Element }, 0.12) end)

	local function selectedList()
		local t = {}
		for _, opt in options do if selected[opt] then table.insert(t, opt) end end
		return t
	end

	local function fire()
		if o.Callback then task.spawn(o.Callback, multi and selectedList() or single) end
	end

	local function display()
		if multi then
			local t = selectedList()
			valueLabel.Text = #t > 0 and table.concat(t, ", ") or "None"
			Library.Flags[flag] = t
		else
			valueLabel.Text = single or "None"
			Library.Flags[flag] = single
		end
		for opt, b in buttons do
			local on = multi and selected[opt] or (not multi and single == opt)
			tween(b, { TextColor3 = on and Theme.Accent or Theme.SubText }, 0.12)
		end
	end

	local function setOpen(v)
		open = v
		local n = #options
		local listH = math.min(n * ITEM_H + math.max(n - 1, 0) * GAP + 6, MAX_H)
		local style = Enum.EasingStyle.Quint
		tween(container, { Size = UDim2.new(1, 0, 0, v and (54 + listH) or 48) }, 0.25, style)
		tween(list, { Size = UDim2.new(1, 0, 0, v and listH or 0) }, 0.25, style)
		tween(arrow, { Rotation = v and 180 or 0 }, 0.2)
		tween(headStroke, { Color = v and Theme.Accent or Theme.Stroke }, 0.15)
	end

	local function build()
		for _, b in buttons do b:Destroy() end
		table.clear(buttons)
		for i, opt in options do
			local b = new("TextButton", {
				Size = UDim2.new(1, 0, 0, ITEM_H), BackgroundColor3 = Theme.ElementHover, BackgroundTransparency = 1,
				Text = opt, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Theme.SubText,
				AutoButtonColor = false, LayoutOrder = i, Parent = list,
			})
			corner(b, 4)
			connect(b.MouseEnter, function() tween(b, { BackgroundTransparency = 0.5 }, 0.1) end)
			connect(b.MouseLeave, function() tween(b, { BackgroundTransparency = 1 }, 0.1) end)
			connect(b.MouseButton1Click, function()
				if multi then
					selected[opt] = not selected[opt] or nil
				else
					single = opt
					setOpen(false)
				end
				display()
				fire()
			end)
			buttons[opt] = b
		end
		display()
	end

	connect(head.MouseButton1Click, function() setOpen(not open) end)

	if multi then
		for _, v in (o.Default or {}) do selected[v] = true end
	else
		single = o.Default
	end
	build()

	local entry = self:_register(o.Name, container, table.concat(options, " "))

	local obj = {}
	function obj:Get() return multi and selectedList() or single end
	function obj:Set(v, silent)
		if multi then
			selected = {}
			for _, x in (v or {}) do selected[x] = true end
		else
			single = v
		end
		display()
		if not silent then fire() end
	end
	function obj:Refresh(newOptions)
		options = newOptions
		entry.Search = string.lower(o.Name .. " " .. table.concat(options, " "))
		build()
		if open then setOpen(true) end
	end
	return obj
end

function Section:AddDropdown(o) return buildDropdown(self, o, false) end
function Section:AddMultiDropdown(o) return buildDropdown(self, o, true) end

function Section:AddColorPicker(o)
	local flag = o.Flag or o.Name
	local h, s, v = (o.Default or Theme.Accent):ToHSV()
	local open = false
	local PANEL_H = 110

	local container = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, ClipsDescendants = true, Parent = self.Content })
	text({ Text = o.Name, Size = UDim2.new(1, -40, 0, 22), TextColor3 = Theme.SubText, Parent = container })
	local swatch = new("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 3), Size = UDim2.fromOffset(32, 16), Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = container })
	corner(swatch, 4)
	local swStroke = stroke(swatch, Theme.Stroke)

	local panel = new("Frame", { Position = UDim2.fromOffset(0, 28), Size = UDim2.new(1, 0, 0, PANEL_H), BackgroundTransparency = 1, Parent = container })
	local sv = new("Frame", { Size = UDim2.new(1, -24, 1, 0), BorderSizePixel = 0, ClipsDescendants = true, BackgroundColor3 = Color3.new(1, 0, 0), Parent = panel })
	corner(sv, 5)
	local white = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 2, Parent = sv })
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }), Parent = white })
	local black = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 3, Parent = sv })
	new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }), Parent = black })
	local svCursor = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, ZIndex = 4, Parent = sv })
	corner(svCursor, 5)
	stroke(svCursor, Color3.new(1, 1, 1), 2)

	local hue = new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 16, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = panel })
	corner(hue, 4)
	local keys = {}
	for i = 0, 6 do table.insert(keys, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6 % 1, 1, 1))) end
	keys[7] = ColorSequenceKeypoint.new(1, Color3.fromHSV(0, 1, 1))
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(keys), Parent = hue })
	local hueCursor = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(1, 4, 0, 4), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = hue })
	corner(hueCursor, 2)
	stroke(hueCursor, Color3.new(0, 0, 0), 1)

	local function apply(silent)
		local c = Color3.fromHSV(h, s, v)
		sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		swatch.BackgroundColor3 = c
		svCursor.Position = UDim2.fromScale(s, 1 - v)
		hueCursor.Position = UDim2.fromScale(0.5, h)
		Library.Flags[flag] = c
		if not silent and o.Callback then task.spawn(o.Callback, c) end
	end

	dragHandler(sv,
		function(m) s = math.clamp((m.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1); v = 1 - math.clamp((m.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1); apply() end,
		function(m) s = math.clamp((m.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1); v = 1 - math.clamp((m.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1); apply() end)
	dragHandler(hue,
		function(m) h = math.clamp((m.Y - hue.AbsolutePosition.Y) / hue.AbsoluteSize.Y, 0, 1); apply() end,
		function(m) h = math.clamp((m.Y - hue.AbsolutePosition.Y) / hue.AbsoluteSize.Y, 0, 1); apply() end)

	connect(swatch.MouseButton1Click, function()
		open = not open
		tween(container, { Size = UDim2.new(1, 0, 0, open and (28 + PANEL_H + 4) or 22) }, 0.25, Enum.EasingStyle.Quint)
		tween(swStroke, { Color = open and Theme.Accent or Theme.Stroke }, 0.15)
	end)

	apply(true)
	self:_register(o.Name, container, "color")
	local obj = {}
	function obj:Get() return Color3.fromHSV(h, s, v) end
	function obj:Set(c) h, s, v = c:ToHSV(); apply() end
	return obj
end

function Section:AddTextbox(o)
	local flag = o.Flag or o.Name
	local container = new("Frame", { Size = UDim2.new(1, 0, 0, 48), BackgroundTransparency = 1, Parent = self.Content })
	text({ Text = o.Name, TextSize = 12, TextColor3 = Theme.SubText, Size = UDim2.new(1, 0, 0, 16), Parent = container })
	local box = new("TextBox", {
		Position = UDim2.fromOffset(0, 20), Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = Theme.Element,
		BorderSizePixel = 0, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Theme.Text,
		PlaceholderText = o.Placeholder or "", PlaceholderColor3 = Theme.SubText,
		Text = o.Default or "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, Parent = container,
	})
	corner(box, 5)
	padding(box, 0, 8, 0, 10)
	local st = stroke(box, Theme.Stroke)
	Library.Flags[flag] = box.Text
	connect(box.Focused, function() tween(st, { Color = Theme.Accent }, 0.15) end)
	connect(box.FocusLost, function(enter)
		tween(st, { Color = Theme.Stroke }, 0.15)
		Library.Flags[flag] = box.Text
		if o.Callback then task.spawn(o.Callback, box.Text, enter) end
	end)
	self:_register(o.Name, container, "textbox input")
	local obj = {}
	function obj:Get() return box.Text end
	function obj:Set(t) box.Text = t; Library.Flags[flag] = t end
	return obj
end

-- Tab ------------------------------------------------------------------------------
local Tab = {}
Tab.__index = Tab

function Tab:AddSection(o)
	local window = self.Window
	local column = (o.Side == "Right") and self.Right or self.Left
	self._count = self._count + 1
	local order = self._count

	local section = new("Frame", {
		Name = o.Name, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Section, BorderSizePixel = 0, LayoutOrder = order, Parent = column,
	})
	corner(section, 8)
	local sectionStroke = stroke(section, Theme.Stroke)
	local uiscale = new("UIScale", { Parent = section })
	listLayout(section, 0)

	local header = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 0, Parent = section })
	local tl = titledLine(header, o.Name)
	tl.Position = UDim2.new(0, 12, 0, 8)
	tl.Size = UDim2.new(1, -24, 0, 18)

	local content = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = 1, Parent = section })
	padding(content, 2, 12, 12, 12)
	listLayout(content, 8)

	local sec = setmetatable({
		Frame = section, Content = content, Name = o.Name, Tab = self, Window = window,
		_items = {}, _scale = uiscale, _stroke = sectionStroke, _column = column, _order = order,
		_floating = false, _searchVisible = true,
	}, Section)
	table.insert(self._sections, sec)
	table.insert(window._allSections, sec)

	-- drag logic: lift out of the column, drop back over the window to reset
	local pending, moved, hovering = false, false, false
	local startMouse, grab = Vector2.zero, Vector2.zero

	local function setDropGlow(over)
		if over == hovering then return end
		hovering = over
		tween(window._mainStroke, { Color = over and Theme.Accent or Theme.Stroke }, 0.15)
	end

	dragHandler(header,
		function(m)
			pending, moved = true, false
			startMouse = m
			grab = m - section.AbsolutePosition
		end,
		function(m)
			if not pending then return end
			if not moved then
				if (m - startMouse).Magnitude < 5 then return end
				moved = true
				if not sec._floating then
					local abs, w = section.AbsolutePosition, section.AbsoluteSize.X
					section.Parent = window.Overlay
					section.Size = UDim2.fromOffset(w, 0)
					section.Position = UDim2.fromOffset(abs.X, abs.Y)
					sec._floating = true
				end
				tween(uiscale, { Scale = 1.03 }, 0.12)
				tween(sectionStroke, { Color = Theme.Accent }, 0.12)
			end
			section.Position = UDim2.fromOffset(m.X - grab.X, m.Y - grab.Y)
			setDropGlow(inside(window.Main, m))
		end,
		function(m)
			setDropGlow(false)
			if not (pending and moved) then pending = false return end
			pending = false
			if inside(window.Main, m) then
				sec:ReturnHome(true)
			else
				tween(uiscale, { Scale = 1 }, 0.15)
			end
		end)

	return sec
end

-- Window ---------------------------------------------------------------------------
local Window = {}
Window.__index = Window

function Window:SetVisible(v)
	self.Visible = v
	if v then
		self.Main.Visible = true
		self.Overlay.Visible = true
		tween(self.Main, { GroupTransparency = 0 }, 0.25)
		tween(self._scale, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	else
		tween(self.Main, { GroupTransparency = 1 }, 0.2)
		tween(self._scale, { Scale = 0.94 }, 0.2)
		task.delay(0.22, function()
			if not self.Visible and self.Main.Parent then
				self.Main.Visible = false
				self.Overlay.Visible = false
			end
		end)
	end
end

function Window:ResetLayout()
	for _, sec in self._allSections do
		sec:ReturnHome(true)
	end
end

function Window:Unload()
	Library:Unload()
end

function Window:Notify(msg, duration)
	duration = duration or 2.5
	local wrap = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, LayoutOrder = math.floor(tick() * 100) % 1000000, Parent = self._toasts })
	local toast = new("Frame", { Size = UDim2.fromScale(1, 1), Position = UDim2.new(1.2, 0, 0, 0), BackgroundColor3 = Theme.Section, BorderSizePixel = 0, Parent = wrap })
	corner(toast, 6)
	stroke(toast, Theme.Accent)
	local bar = new("Frame", { Size = UDim2.new(0, 3, 1, -14), Position = UDim2.fromOffset(8, 7), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = toast })
	corner(bar, 2)
	text({ Text = msg, Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -28, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = toast })
	tween(toast, { Position = UDim2.new() }, 0.35, Enum.EasingStyle.Back)
	task.delay(duration, function()
		if not toast.Parent then return end
		tween(toast, { Position = UDim2.new(1.2, 0, 0, 0) }, 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.28, function() wrap:Destroy() end)
	end)
end

function Window:ApplySearch(query)
	local q = string.lower(query or "")
	q = q:match("^%s*(.-)%s*$")
	self._query = q
	local searching = q ~= ""
	local firstTab, anyHit = nil, false

	for _, tab in self.Tabs do
		local tabMatch = searching and string.find(string.lower(tab.Name), q, 1, true) ~= nil
		local tabHits = 0
		for _, sec in tab._sections do
			local secMatch = tabMatch or (searching and string.find(string.lower(sec.Name), q, 1, true) ~= nil)
			local hits = 0
			for _, e in sec._items do
				local vis = (not searching) or secMatch or string.find(e.Search, q, 1, true) ~= nil
				e.Frame.Visible = vis
				if vis then hits += 1 end
			end
			sec._searchVisible = (not searching) or hits > 0
			sec:_refreshVisible()
			tabHits += hits
		end
		local show = (not searching) or tabHits > 0 or tabMatch
		tab._button.Visible = show
		if show then
			anyHit = true
			if not firstTab then firstTab = tab end
		end
	end

	self._noResults.Visible = searching and not anyHit
	if searching and firstTab and (not self.CurrentTab or not self.CurrentTab._button.Visible) then
		self:SelectTab(firstTab)
	end
end

function Window:ClearSearch()
	self._searchBox.Text = ""
end

function Window:SelectTab(tab)
	local changed = self.CurrentTab ~= tab
	self.CurrentTab = tab
	for _, t in self.Tabs do
		local active = (t == tab)
		t._page.Visible = active
		tween(t._indicator, { Size = UDim2.fromOffset(3, active and 18 or 0) }, 0.2, Enum.EasingStyle.Quint)
		tween(t._button, { BackgroundTransparency = active and 0.6 or 1 }, 0.2)
		tween(t._name, { TextColor3 = active and Theme.Text or Theme.SubText }, 0.2)
		if t._icon then tween(t._icon, { ImageColor3 = active and Theme.Accent or Theme.SubText }, 0.2) end
	end

	-- floating cards belong to their tab
	for _, sec in self._allSections do sec:_refreshVisible() end

	if changed then
		-- page slide + fade
		tab._page.GroupTransparency = 1
		tab._page.Position = UDim2.fromOffset(0, 16)
		tween(tab._page, { GroupTransparency = 0 }, 0.28)
		tween(tab._page, { Position = UDim2.new() }, 0.35, Enum.EasingStyle.Quint)

		-- staggered section pop-in
		for i, sec in ipairs(tab._sections) do
			if not sec._floating then
				sec._scale.Scale = 0.94
				task.delay((i - 1) * 0.06, function()
					if sec.Frame.Parent then
						tween(sec._scale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)
					end
				end)
			end
		end

		-- header text swap
		self._headTitle.TextTransparency = 1
		self._headDesc.TextTransparency = 1
		tween(self._headTitle, { TextTransparency = 0 }, 0.25)
		tween(self._headDesc, { TextTransparency = 0 }, 0.35)
	end

	self._headTitle.Text = tab.Name
	self._headDesc.Text = tab.Description or ""
	if tab.Icon then
		self._headIcon.Image = tab.Icon
		self._headIcon.Visible = true
	else
		self._headIcon.Visible = false
	end
end

function Window:AddTab(o)
	local tab = setmetatable({ Name = o.Name, Description = o.Description, Icon = o.Icon, Window = self, _count = 0, _sections = {} }, Tab)

	local btn = new("TextButton", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = Theme.Element, BackgroundTransparency = 1, Text = "", AutoButtonColor = false, LayoutOrder = #self.Tabs + 1, Parent = self._tabList })
	corner(btn, 6)
	local ind = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(3, 0), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = btn })
	corner(ind, 2)
	if o.Icon then
		tab._icon = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 16, 0.5, -9), Size = UDim2.fromOffset(18, 18), Image = o.Icon, ImageColor3 = Theme.SubText, Parent = btn })
	end
	local name = text({ Text = o.Name, Position = UDim2.fromOffset(o.Icon and 44 or 18, 0), Size = UDim2.new(1, -50, 1, 0), TextColor3 = Theme.SubText, Parent = btn })
	connect(btn.MouseEnter, function()
		if self.CurrentTab ~= tab then
			tween(btn, { BackgroundTransparency = 0.8 }, 0.12)
			tween(name, { Position = UDim2.fromOffset((o.Icon and 44 or 18) + 4, 0) }, 0.12)
		end
	end)
	connect(btn.MouseLeave, function()
		if self.CurrentTab ~= tab then tween(btn, { BackgroundTransparency = 1 }, 0.12) end
		tween(name, { Position = UDim2.fromOffset(o.Icon and 44 or 18, 0) }, 0.12)
	end)
	connect(btn.MouseButton1Click, function() self:SelectTab(tab) end)

	local page = new("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false, Parent = self._pages })
	local scroll = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2,
		ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = page,
	})
	padding(scroll, 4, 14, 16, 22)
	local cols = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = scroll })
	listLayout(cols, 12, Enum.FillDirection.Horizontal)
	local function column(order)
		local f = new("Frame", { Size = UDim2.new(0.5, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = order, Parent = cols })
		listLayout(f, 12)
		return f
	end
	tab.Left, tab.Right = column(1), column(2)
	tab._page, tab._button, tab._indicator, tab._name = page, btn, ind, name

	table.insert(self.Tabs, tab)
	if #self.Tabs == 1 then self:SelectTab(tab) end
	return tab
end

function Library:CreateWindow(o)
	o = o or {}
	local parent = o.Parent or Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, c in parent:GetChildren() do
		if c.Name == GUI_NAME then c:Destroy() end
	end

	local gui = new("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = parent })
	Library._gui = gui

	local self = setmetatable({ Tabs = {}, Visible = true, _allSections = {}, _query = "" }, Window)

	local Main = new("CanvasGroup", {
		Name = "Main", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(o.Width or 780, o.Height or 520), BackgroundColor3 = Theme.Background,
		BorderSizePixel = 0, GroupTransparency = 1, ZIndex = 1, Parent = gui,
	})
	corner(Main, 10)
	self._mainStroke = stroke(Main, Theme.Stroke)
	local scale = new("UIScale", { Scale = 0.94, Parent = Main })
	local Overlay = new("Frame", { Name = "Overlay", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 10, Parent = gui })
	self.Main, self.Overlay, self._scale = Main, Overlay, scale

	-- toast holder (lives outside Main so toasts still show when the menu is hidden)
	local toasts = new("Frame", { Name = "Toasts", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Size = UDim2.new(0, 260, 0.6, 0), BackgroundTransparency = 1, ZIndex = 20, Parent = gui })
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom, Parent = toasts })
	self._toasts = toasts

	-- sidebar
	local sidebar = new("Frame", { Size = UDim2.new(0, 180, 1, 0), BackgroundColor3 = Theme.Sidebar, BorderSizePixel = 0, Parent = Main })
	local accentHex = Theme.Accent:ToHex()
	local logo = new("Frame", { Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, Parent = sidebar })
	text({
		RichText = true, Font = Enum.Font.GothamBold, TextSize = 19,
		Text = string.format('%s<font color="#%s">%s</font>', o.Title or "Menu", accentHex, o.TitleAccent or "Lib"),
		Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -20, 1, 0), Parent = logo,
	})

	-- search bar
	local searchFrame = new("Frame", { Position = UDim2.fromOffset(10, 70), Size = UDim2.new(1, -20, 0, 30), BackgroundColor3 = Theme.Element, BorderSizePixel = 0, Parent = sidebar })
	corner(searchFrame, 6)
	local searchStroke = stroke(searchFrame, Theme.Stroke)
	local searchBox = new("TextBox", {
		Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -34, 1, 0), BackgroundTransparency = 1,
		BorderSizePixel = 0, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = Theme.Text,
		PlaceholderText = "Search features...", PlaceholderColor3 = Theme.SubText, Text = "",
		ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, Parent = searchFrame,
	})
	local clearBtn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(18, 18),
		BackgroundTransparency = 1, Text = "×", Font = Enum.Font.GothamBold, TextSize = 16,
		TextColor3 = Theme.SubText, TextTransparency = 1, Visible = false, Parent = searchFrame,
	})
	self._searchBox = searchBox
	connect(searchBox.Focused, function() tween(searchStroke, { Color = Theme.Accent }, 0.15) end)
	connect(searchBox.FocusLost, function() tween(searchStroke, { Color = Theme.Stroke }, 0.15) end)
	connect(searchBox:GetPropertyChangedSignal("Text"), function()
		local has = searchBox.Text ~= ""
		if has then clearBtn.Visible = true end
		tween(clearBtn, { TextTransparency = has and 0 or 1 }, 0.15)
		if not has then task.delay(0.16, function() if searchBox.Text == "" then clearBtn.Visible = false end end) end
		self:ApplySearch(searchBox.Text)
	end)
	connect(clearBtn.MouseEnter, function() tween(clearBtn, { TextColor3 = Theme.Accent }, 0.1) end)
	connect(clearBtn.MouseLeave, function() tween(clearBtn, { TextColor3 = Theme.SubText }, 0.1) end)
	connect(clearBtn.MouseButton1Click, function() searchBox.Text = "" end)

	local tabList = new("Frame", { Position = UDim2.fromOffset(10, 112), Size = UDim2.new(1, -20, 1, -152), BackgroundTransparency = 1, Parent = sidebar })
	listLayout(tabList, 6)
	self._tabList = tabList
	text({ Text = o.Version or "VERSION 2.0", TextSize = 10, TextColor3 = Theme.SubText, Position = UDim2.new(0, 20, 1, -30), Size = UDim2.new(1, -20, 0, 20), Parent = sidebar })

	-- content
	local content = new("Frame", { Position = UDim2.fromOffset(180, 0), Size = UDim2.new(1, -180, 1, 0), BackgroundTransparency = 1, Parent = Main })
	local head = new("Frame", { Size = UDim2.new(1, 0, 0, 70), BackgroundTransparency = 1, Parent = content })
	local iconBox = new("Frame", { Position = UDim2.fromOffset(22, 15), Size = UDim2.fromOffset(40, 40), BackgroundColor3 = Theme.Element, BorderSizePixel = 0, Parent = head })
	corner(iconBox, 8)
	self._headIcon = new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(20, 20), ImageColor3 = Theme.Accent, Parent = iconBox })
	self._headTitle = text({ Font = Enum.Font.GothamBold, TextSize = 18, Position = UDim2.fromOffset(74, 14), Size = UDim2.new(1, -160, 0, 24), Parent = head })
	self._headDesc = text({ TextSize = 12, TextColor3 = Theme.SubText, Position = UDim2.fromOffset(74, 38), Size = UDim2.new(1, -160, 0, 18), Parent = head })
	self._pages = new("Frame", { Position = UDim2.fromOffset(0, 70), Size = UDim2.new(1, 0, 1, -70), BackgroundTransparency = 1, ClipsDescendants = true, Parent = content })
	self._noResults = text({
		Text = "No features found", TextSize = 14, TextColor3 = Theme.SubText, TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0.4, 0), Visible = false, Parent = self._pages,
	})

	-- window controls
	local function ctrl(txt, xOff, fn)
		local b = new("TextButton", { Text = txt, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = Theme.SubText, BackgroundTransparency = 1, Size = UDim2.fromOffset(34, 28), Position = UDim2.new(1, xOff, 0, 10), ZIndex = 5, Parent = Main })
		connect(b.MouseEnter, function() tween(b, { TextColor3 = Theme.Accent }, 0.12) end)
		connect(b.MouseLeave, function() tween(b, { TextColor3 = Theme.SubText }, 0.12) end)
		connect(b.MouseButton1Click, fn)
	end
	ctrl("—", -76, function() self:SetVisible(false) end)
	ctrl("×", -40, function() Library:Unload() end)

	-- window dragging (header + logo area)
	local grab = Vector2.zero
	local function attachWindowDrag(frame)
		dragHandler(frame,
			function(m) grab = m - (Main.AbsolutePosition + Main.AbsoluteSize / 2) end,
			function(m) Main.Position = UDim2.fromOffset(m.X - grab.X, m.Y - grab.Y) end)
	end
	attachWindowDrag(head)
	attachWindowDrag(logo)

	-- window keybind
	local toggleKey = o.Keybind or Enum.KeyCode.RightShift
	connect(UserInputService.InputBegan, function(input, processed)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == toggleKey then
			self:SetVisible(not self.Visible)
		end
	end)

	-- open animation
	tween(Main, { GroupTransparency = 0 }, 0.35)
	tween(scale, { Scale = 1 }, 0.4, Enum.EasingStyle.Back)

	return self
end

function Library:Unload()
	for _, c in connections do pcall(function() c:Disconnect() end) end
	table.clear(connections)
	if Library._gui then
		Library._gui:Destroy()
		Library._gui = nil
	end
	table.clear(Library.Flags)
	if _G[GLOBAL_KEY] == Library then _G[GLOBAL_KEY] = nil end
end

_G[GLOBAL_KEY] = Library
return Library
