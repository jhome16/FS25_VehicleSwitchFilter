-- VehicleSwitchFilter.lua
VehicleSwitchFilter = {}
VehicleSwitchFilter.debugEnabled = false -- RELEASE: set false to hide logs
VehicleSwitchFilter.enabled = false
VehicleSwitchFilter.orgTabNext = nil
VehicleSwitchFilter.orgTabBack = nil
VehicleSwitchFilter.lastVehicleIndex = 1

-- Icon settings (default), Can be toggled in console to show text (on/off) instead
VehicleSwitchFilter.useIcon = true
VehicleSwitchFilter.iconChar = "<S>"

--To Show Center Warning Message When Toggle ON/OFF, also a console command
VehicleSwitchFilter.useWarningMessageForToggle = false

VehicleSwitchFilter.posNudgeX = -0.06  -- positive = right, negative = left -0.055
VehicleSwitchFilter.posNudgeY = 0.127 -- negative = down, positive = up 0.125


local function dbg(msg)
    if VehicleSwitchFilter.debugEnabled then
        print(string.format("VSF_DEBUG: %s", tostring(msg)))
    end
end

-- THE RIGID VALIDATOR
function VehicleSwitchFilter:isVehicleValid(veh)
    if veh == nil or veh.isDeleted then return false end
    if veh.spec_locomotive ~= nil then
        if not g_gameSettings:getValue("switcherTrain") then return false end
    end
	
	-- EXCLUDE AI WORKERS FROM "FS25_WorkingNeighborOnField"
	--local okName, name = pcall(function() return (veh.getFullName and veh:getFullName()) or "" end)
	--name = (okName and tostring(name):lower()) or ""
	--if name:find("%(ai worker%s+neighbou?r") then return false end
	
	-- safe name fetch
	local okName, name = pcall(function() return (veh.getFullName and veh:getFullName()) or "" end)
	name = (okName and tostring(name):lower()) or ""

	-- safe owner/farm id fetch
	local function getOwnerFarmIdSafe(v)
		if v == nil then return nil end
		if v.ownerFarmId ~= nil then return v.ownerFarmId end
		if v.farmId ~= nil then return v.farmId end
		if v.getOwnerFarmId ~= nil then
			local ok, fid = pcall(v.getOwnerFarmId, v)
			if ok then return fid end
		end
		return nil
	end

	-- determine local player's farm id (defensive)
	local function getLocalPlayerFarmId()
		if g_currentMission == nil then return nil end
		if g_currentMission.player ~= nil and g_currentMission.player.farmId ~= nil then
			return g_currentMission.player.farmId
		end
		if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
			return g_localPlayer.farmId
		end
		if g_currentMission.getFarmId ~= nil then
			local ok, fid = pcall(g_currentMission.getFarmId, g_currentMission)
			if ok then return fid end
		end
		return nil
	end

	-- precise neighbour exclusion: name pattern + different owner farm
	local ownerFarmId = getOwnerFarmIdSafe(veh)
	local localFarmId = getLocalPlayerFarmId()
	local isNeighbourName = name:find("%(ai worker%s+neighbou?r")
	if isNeighbourName and ownerFarmId ~= nil and localFarmId ~= nil and ownerFarmId ~= localFarmId then
		-- This is a neighbour's AI worker (not owned by the player) -> exclude
		return false
	end


    local isRunning = (veh.getIsMotorStarted ~= nil and veh:getIsMotorStarted())
    local isAI = (veh.getIsAIActive ~= nil and veh:getIsAIActive())
    return isRunning or isAI
end

-- ENHANCED SEARCH LOGIC WITH LIST DUMP
function VehicleSwitchFilter:findNextFilteredVehicle(direction)
    local vs = g_currentMission.vehicleSystem
    local enterables = vs.enterables
    local count = #enterables
    
    if count <= 1 then 
        dbg("Search Cancelled: Only " .. count .. " vehicle(s) in the world.")
        return nil 
    end

    local currentVehicle = g_currentMission.controlledVehicle
    
    -- --- DEBUG LIST DUMP ---
    if self.debugEnabled then
        dbg("--- CURRENT ENTERABLES LIST ---")
        for i, v in ipairs(enterables) do
            local isValid = self:isVehicleValid(v)
            local status = isValid and "[VALID]" or "[SKIPPED]"
            local isCurrent = (v == g_currentMission.controlledVehicle) and " << CURRENT" or ""
            local name = v.getFullName ~= nil and v:getFullName() or "Unknown"
            
            dbg(string.format("Index %d: %-10s %s%s", i, status, name, isCurrent))
        end
        dbg("-------------------------------")
    end
    -- --- END DEBUG LIST DUMP ---

    -- IDENTIFY STARTING POINT
    local currentIndex = 0
    for i, v in ipairs(enterables) do
        if v == currentVehicle then
            currentIndex = i
            break
        end
    end

    -- FALLBACK LOGIC
    if currentIndex == 0 then
        currentIndex = self.lastVehicleIndex or 1
        dbg("Active vehicle not in list (common with Trains). Starting from index: " .. currentIndex)
    end

    -- THE SEARCH LOOP
    for step = 1, count do
        local i = ((currentIndex - 1 + (step * direction)) % count) + 1
        local veh = enterables[i]
        
        if veh ~= nil and veh ~= currentVehicle then
            if self:isVehicleValid(veh) then
                self.lastVehicleIndex = i 
                dbg("RESULT: Switching to Index " .. i)
                return veh
            end
        end
    end

	local textKey = "warning_noRunningVehicles"
	local text = g_i18n:getText(textKey)
	g_currentMission:showBlinkingWarning(text, 1000)
    
    dbg("RESULT: No valid targets found in loop.")
    return nil
end

-- THE ACTION HANDLER
function VehicleSwitchFilter:onToggleAction(actionName, inputValue, callbackState, isAnalog)
    if inputValue > 0 and g_gui.currentGui == nil then 
        self:toggleFilter()
    end
end

function VehicleSwitchFilter:onTabAction(targetInstance, actionName, ...)
    if self.enabled and g_gui.currentGui == nil then
        local direction = (actionName == "SWITCH_VEHICLE") and 1 or -1
        local nextVeh = self:findNextFilteredVehicle(direction)
        
        if nextVeh ~= nil then
            -- We use g_localPlayer because that's the 'player' object 
            if g_localPlayer ~= nil then
                if g_server ~= nil then
                    -- Singleplayer/Host: Call it directly as the game does
                    g_localPlayer:requestToEnterVehicle(nextVeh)
                else
                    -- Multiplayer Client: We must tell the server to 
                    -- execute 'requestToEnterVehicle' for us.
                    g_client:getServerConnection():sendEvent(VehicleSwitchEvent.new(nextVeh))
                end
            end
            return -- Block the default game TAB so we don't double-jump
        end
    end

    -- Standard fallback if mod is OFF or no valid vehicle found
    if actionName == "SWITCH_VEHICLE" and self.orgTabNext ~= nil then
        return self.orgTabNext(targetInstance, actionName, ...)
    elseif actionName == "SWITCH_VEHICLE_BACK" and self.orgTabBack ~= nil then
        return self.orgTabBack(targetInstance, actionName, ...)
    end
end

-- INPUT REGISTRATION 
function VehicleSwitchFilter.registerGlobalActionEvents(playerInputComponent, contextName)
    -- Only register for the local player
    if playerInputComponent.player ~= nil and playerInputComponent.player.isOwner then
        local self = VehicleSwitchFilter
        
        -- Register the toggle key
        local _, eventId = g_inputBinding:registerActionEvent("TOGGLE_VEHICLE_FILTER", self, self.onToggleAction, false, true, false, true)
        if eventId then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_HIGH)
            g_inputBinding:setActionEventText(eventId, g_i18n:getText("KEY_TEXT_DISPLAY"))
        end
    end
end

-- HUD and append helpers ----------------------------------------------------

-- Consolidated helper to get HUD and speedMeter
function VehicleSwitchFilter:_getHudAndSpeedMeter()
    if g_currentMission == nil then return nil, nil end
    local hud = (g_currentMission.inGameMenu and g_currentMission.inGameMenu.hud) or g_currentMission.hud
    if hud == nil then return nil, nil end
    return hud, hud.speedMeter
end

-- Render helper used by both appended hook and fallback draw (icon + text)
function VehicleSwitchFilter:_renderStatusAt(posX, posY, size)
	
    -- Hard Check: Is the HUD globally hidden (F11 / No HUD mode)?
    if g_currentMission.hud ~= nil and not g_currentMission.hud.isVisible then
		dbg("VSF: Render- HUD Hidden.")
        return
    end
	
	-- Hard Check: Is the SpeedMeter specifically supposed to be hidden?
    local _, speedMeter = self:_getHudAndSpeedMeter()
	
    if speedMeter ~= nil then
        if speedMeter.getIsVisible ~= nil and not speedMeter:getIsVisible() then
			dbg("VSF: Render- getIsVisible.")
            return
        end
        -- If the speedmeter has no vehicle, it shouldn't have an icon
        if speedMeter.vehicle == nil then
			dbg("VSF: Render- No SpeedMeter.")
            return
        end
    end
	
    if self.useIcon then
        local iconSize = size * 1.1 -- Not using Icon, still just Text
        setTextColor(self.enabled and 0.1 or 0.75, self.enabled and 1 or 0.75, 0.75, 1)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_TOP)
        setTextBold(true)
        renderText(posX, posY, iconSize, self.iconChar)
        -- restore defaults
        setTextColor(1,1,1,1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
        setTextBold(false)
    else
        -- Text rendering (fallback)
        local statusText = self.enabled and "VSF:ON" or "VSF:OFF"
        local r,g,b = self.enabled and 0.1 or 0.75, self.enabled and 1 or 0.75, 0.75

        setTextColor(r,g,b,1)
        setTextAlignment(RenderText.ALIGN_CENTER)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_TOP)
        setTextBold(true)
        renderText(posX, posY, size, statusText)
        setTextColor(1,1,1,1)
        setTextAlignment(RenderText.ALIGN_LEFT)
        setTextVerticalAlignment(RenderText.VERTICAL_ALIGN_BASELINE)
        setTextBold(false)
    end
end

-- local helper, file-scoped (preferred)
local function tryAppendToSpeedMeter()
    -- 1) Try instance hook: g_currentMission.hud.speedMeter
    if g_currentMission ~= nil then
        local hud = (g_currentMission.inGameMenu and g_currentMission.inGameMenu.hud) or g_currentMission.hud
        if hud ~= nil and hud.speedMeter ~= nil and hud.speedMeter.draw ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
            hud.speedMeter.draw = Utils.appendedFunction(hud.speedMeter.draw, function(self)
                -- Defensive wrapper: avoid calling engine functions with invalid objects
                local ok, err = pcall(function()
					if self.getIsVisible ~= nil and not self:getIsVisible() then
						return
					end
                    if self == nil or self == 0 then
                        if VehicleSwitchFilter.debugEnabled then dbg("VSF: hud.speedMeter instance invalid in appended draw") end
                        return
                    end

                    -- One-line tuned posX/posY (uses hud.speedMeter.x, speedTextOffsetX, speedGaugeCenterOffsetY, speedTextOffsetY)
                    local posX = (type(self.x) == "number" and (self.x + (self.speedTextOffsetX or 0) + (VehicleSwitchFilter.posNudgeX))) or (g_screenWidth - 0.12)
					local posY = (type(self.speedGaugeCenterOffsetY) == "number" and (self.speedGaugeCenterOffsetY + (self.speedTextOffsetY or 0) + (VehicleSwitchFilter.posNudgeY))) or 0.12
                    local size = 0.012 * (g_gameSettings and g_gameSettings.uiScale or 1)

                    VehicleSwitchFilter:_renderStatusAt(posX, posY, size)
                end)
                if not ok then
                    dbg("VSF_ERROR: appended hud.speedMeter.draw pcall failed: " .. tostring(err))
                end
            end)
            VehicleSwitchFilter._vsf_appended = true
            if VehicleSwitchFilter.debugEnabled then dbg("VSF: Appended to hud.speedMeter.draw (instance)") end
            return true
        end
    end

    -- 2) Fallback: try global SpeedMeterDisplay class (older approach)
    if SpeedMeterDisplay ~= nil and SpeedMeterDisplay.draw ~= nil and Utils ~= nil and Utils.appendedFunction ~= nil then
        SpeedMeterDisplay.draw = Utils.appendedFunction(SpeedMeterDisplay.draw, function(self)
            local ok, err = pcall(function()
                if self == nil or self == 0 then
                    if VehicleSwitchFilter.debugEnabled then dbg("VSF: SpeedMeterDisplay instance invalid in appended draw") end
                    return
                end

                local posX = (type(self.gaugeCenterX) == "number" and self.gaugeCenterX) or (g_screenWidth - 0.12)
                local posY = (type(self.gaugeCenterY) == "number" and (self.gaugeCenterY - (self.speedIndicatorRadiusY or 60) * 0.9)) or 0.12
                local size = 0.013 * (g_gameSettings and g_gameSettings.uiScale or 1)

                VehicleSwitchFilter:_renderStatusAt(posX, posY, size)
            end)
            if not ok then
                dbg("VSF_ERROR: appended SpeedMeterDisplay.draw pcall failed: " .. tostring(err))
            end
        end)
        VehicleSwitchFilter._vsf_appended = true
        if VehicleSwitchFilter.debugEnabled then dbg("VSF: Appended to SpeedMeterDisplay.draw (global)") end
        return true
    end

    return false
end

-- One-time fallback debug guard
VehicleSwitchFilter._vsf_loggedFallback = VehicleSwitchFilter._vsf_loggedFallback or false

-- Fallback draw (called by mod event listener)
function VehicleSwitchFilter:draw()
	-- Kill the draw immediately if not in a vehicle
    if g_currentMission.controlledVehicle == nil then return end
    if g_client == nil then return end

    local hud, speedMeter = self:_getHudAndSpeedMeter()
    if hud == nil then 
		return 
	end
    if hud.isVisible ~= nil and not hud.isVisible then 
		return 
	end
	
	-- ADD THIS: Check if the speedMeter specifically is visible
    if speedMeter ~= nil and speedMeter.getIsVisible ~= nil then
        if not speedMeter:getIsVisible() then return end
    end

    local posX, posY, size
    if speedMeter ~= nil and speedMeter.gaugeCenterX ~= nil and speedMeter.gaugeCenterY ~= nil then
        posX = speedMeter.gaugeCenterX
        posY = speedMeter.gaugeCenterY - (speedMeter.speedIndicatorRadiusY or 60) * 0.9
        size = 0.013 * (g_gameSettings and g_gameSettings.uiScale or 1)
    else
        posX = g_screenWidth - 0.12
        posY = 0.12
        size = 0.014
        if self.debugEnabled and not self._vsf_loggedFallback then
            dbg("VSF: speedMeter missing in draw(), using fallback coords")
            self._vsf_loggedFallback = true
        end
    end

    self:_renderStatusAt(posX, posY, size)
end

-- INITIALIZATION (modified loadMap with clean append retry)
function VehicleSwitchFilter:loadMap(name)
    -- Hook the TAB logic via the registerActionEvent hijack
    if g_inputBinding ~= nil then
        local orgRegister = g_inputBinding.registerActionEvent
        g_inputBinding.registerActionEvent = function(bindingSelf, actionName, target, callback, ...)
            if actionName == "SWITCH_VEHICLE" then
                if self.orgTabNext == nil then self.orgTabNext = callback end
                local wrappedCallback = function(t, a, ...) return self:onTabAction(t, a, ...) end
                return orgRegister(bindingSelf, actionName, target, wrappedCallback, ...)
            elseif actionName == "SWITCH_VEHICLE_BACK" then
                if self.orgTabBack == nil then self.orgTabBack = callback end
                local wrappedCallback = function(t, a, ...) return self:onTabAction(t, a, ...) end
                return orgRegister(bindingSelf, actionName, target, wrappedCallback, ...)
            end
            return orgRegister(bindingSelf, actionName, target, callback, ...)
        end
    end

    -- Tell the engine to call our registration function whenever input is refreshed
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents, 
        VehicleSwitchFilter.registerGlobalActionEvents
    )
    
    -- Console commands
    addConsoleCommand("vsfDebug", "Toggles VSF Debug Logs", "toggleDebug", self)
    addConsoleCommand("vsfToggle", "Toggles motor filter", "toggleFilter", self)
    addConsoleCommand("vsfIcon", "Toggle VSF icon/text display", "toggleIcon", VehicleSwitchFilter)
	addConsoleCommand("vsfWarnMessage", "Toggle VSF for Warning Message, (Toggle if Running)", "toggleWM", VehicleSwitchFilter)
    addConsoleCommand("vsfDumpDisplays", "Dump candidate HUD/display globals for VSF debugging", "_vsf_dumpDisplays", VehicleSwitchFilter)

    dbg("VehicleSwitchFilter Loaded with Global Hook")

    -- Attempt to append now; if not available, schedule retries
    if not tryAppendToSpeedMeter() then
        -- schedule retries via a temporary update override that will try a few times then restore
        self._vsf_appendRetries = 0
        self._vsf_appendTimer = 0

        local originalUpdate = VehicleSwitchFilter.update
        local function restoreOriginalUpdate()
            -- clear retry state and restore original update (or nil)
            self._vsf_appendRetries = nil
            self._vsf_appendTimer = nil
            if originalUpdate == nil then
                VehicleSwitchFilter.update = nil
            else
                VehicleSwitchFilter.update = originalUpdate
            end
        end

        VehicleSwitchFilter.update = function(self, dt)
            -- call original update if present
            if originalUpdate ~= nil then originalUpdate(self, dt) end

            if self._vsf_appended then
                -- success: restore original update and clear retry state
                if self.debugEnabled then dbg("VSF: append succeeded, restoring update") end
                restoreOriginalUpdate()
                return
            end

            self._vsf_appendTimer = (self._vsf_appendTimer or 0) + dt
            if self._vsf_appendTimer >= 500 then -- try every 500 ms
                self._vsf_appendTimer = 0
                self._vsf_appendRetries = (self._vsf_appendRetries or 0) + 1
                if tryAppendToSpeedMeter() or (self._vsf_appendRetries >= 10) then
                    -- either succeeded or exhausted retries; stop retrying
                    if not self._vsf_appended and self.debugEnabled then
                        dbg("VSF: Failed to append after retries; using fallback draw")
                    end
                    restoreOriginalUpdate()
                end
            end
        end
    end
end

function VehicleSwitchFilter:toggleDebug()
    self.debugEnabled = not self.debugEnabled
    print("VSF_DEBUG: Logging is now " .. (self.debugEnabled and "ENABLED" or "DISABLED"))
end

function VehicleSwitchFilter:toggleFilter(noEventSend)
    self.enabled = not self.enabled
    
    -- Visual feedback
    if g_currentMission ~= nil then
		-- Get localized "ON" or "OFF" using the new unique keys
		local statusText = self.enabled and g_i18n:getText("vsf_ui_on") or g_i18n:getText("vsf_ui_off")
    
		if self.useWarningMessageForToggle then
			-- Use string.format to inject the localized status into the localized label
			local warningText = string.format(g_i18n:getText("warning_motorFilterStatus"), statusText)
			g_currentMission:showBlinkingWarning(warningText, 2000)
		end
    
    dbg("Filter Toggled: " .. statusText)
	end

    -- If we wanted to sync this state to the server for UI purposes, 
    -- we would trigger another event here. 
    -- For now, keeping it local is fine as long as the Switching Event (Step 1) works.
end

-- Toggle icon/text display
function VehicleSwitchFilter:toggleIcon()
    self.useIcon = not self.useIcon
    dbg("VSF: useIcon = " .. tostring(self.useIcon))
    local mode = self.useIcon and "ICON" or "TEXT"
    if g_currentMission ~= nil then
        g_currentMission:showBlinkingWarning("VSF Display Mode: " .. mode, 1500)
    end
end

-- Toggle Warning Message display for (Toggle if Running)
function VehicleSwitchFilter:toggleWM()
    self.useWarningMessageForToggle = not self.useWarningMessageForToggle
    dbg("VSF: useWarningMessageForToggle = " .. tostring(self.useWarningMessageForToggle))
end

-- Helper to print a field (keeps your original formatting)
local function _vsf_printField(name, value)
    local t = type(value)
    if t == "number" or t == "string" or t == "boolean" then
        dbg(string.format("    %s = %s (%s)", name, tostring(value), t))
    else
        dbg(string.format("    %s = <%s>", name, t))
    end
end

-- Temporary neighbor-worker field dumper (call with console command "vsfDumpNeighbors")
function VehicleSwitchFilter.dumpNeighborFields()
    pcall(function()
        if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
            print("VSF_DUMP: no mission or vehicleSystem")
            return
        end

        local enterables = g_currentMission.vehicleSystem.enterables or {}
        for i, v in ipairs(enterables) do
            local okName, name = pcall(function() return (v.getFullName and v:getFullName()) or "" end)
            name = (okName and tostring(name)) or "<error>"
            local lname = name:lower()
            if lname:find("neigh") or lname:find("neighbor") or lname:find("neighbour") then
                print(("VSF_DUMP: Index=%d Name=%s"):format(i, name))
                print("  typeName=" .. tostring(v.typeName))
                print("  configFileName=" .. tostring(v.configFileName))
                local keys = {
                    "spec_aiWorker","spec_fieldWorker","spec_neighborFieldWorker","spec_neighbourFieldWorker",
                    "isFieldWorker","isWorker","isNeighborFieldWorker","isNeighbourFieldWorker",
                    "aiTrafficDriver","aiDriver","spec_aiVehicle"
                }
                for _, k in ipairs(keys) do
                    local ok, val = pcall(function() return v[k] end)
                    print(("  %s = %s"):format(k, tostring(ok and val or "<error>")))
                end
                local count = 0
                for fk, fv in pairs(v) do
                    if count >= 30 then break end
                    print(("  FIELD: %s  (type=%s)"):format(tostring(fk), type(fv)))
                    count = count + 1
                end
                print("----")
            end
        end
    end)
end

addConsoleCommand("vsfDumpNeighbors", "Dump neighbor worker fields", "dumpNeighborFields", VehicleSwitchFilter)

-- VSF deep dump for neighbor vs Courseplay detection
function VehicleSwitchFilter.deepDump()
	pcall(function()
		if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
			print("VSF_DEEP: no mission or vehicleSystem")
			return
		end

		local enterables = g_currentMission.vehicleSystem.enterables or {}
		for i, v in ipairs(enterables) do
			local okName, name = pcall(function() return (v.getFullName and v:getFullName()) or "" end)
			name = (okName and tostring(name)) or "<error>"
			local lname = name:lower()
			if lname:find("neigh") or lname:find("neighbor") or lname:find("neighbour") then
				print(("VSF_DEEP: Index=%d Name=%s"):format(i, name))
				-- basic metadata
				print("  typeName=" .. tostring(v.typeName))
				print("  configFileName=" .. tostring(v.configFileName))
				-- farm/owner info
				local okFarm, farmId = pcall(function()
					return v.ownerFarmId or v.farmId or (v.getOwnerFarmId and v:getOwnerFarmId())
				end)
				print(("  owner/farm id = %s"):format(tostring(okFarm and farmId or "<error>")))
				-- isAI / isRunning
				local okAI, isAI = pcall(function() return v.getIsAIActive and v:getIsAIActive() end)
				local okRun, isRun = pcall(function() return v.getIsMotorStarted and v:getIsMotorStarted() end)
				print(("  isAI=%s isRunning=%s"):format(tostring(okAI and isAI or "<error>"), tostring(okRun and isRun or "<error>")))

				-- spec_cpAIImplement details (if present)
				if v.spec_cpAIImplement ~= nil then
					print("  spec_cpAIImplement present; dumping keys:")
					for k, val in pairs(v.spec_cpAIImplement) do
						local t = type(val)
						if t == "number" or t == "string" or t == "boolean" then
							print(("    cp.%s = %s"):format(tostring(k), tostring(val)))
						else
							print(("    cp.%s = <%s>"):format(tostring(k), t))
						end
					end
				else
					print("  spec_cpAIImplement = nil")
				end

				-- spec_aiVehicle details (if present)
				if v.spec_aiVehicle ~= nil then
					print("  spec_aiVehicle present; dumping keys:")
					for k, val in pairs(v.spec_aiVehicle) do
						local t = type(val)
						if t == "number" or t == "string" or t == "boolean" then
							print(("    ai.%s = %s"):format(tostring(k), tostring(val)))
						else
							print(("    ai.%s = <%s>"):format(tostring(k), t))
						end
					end
				else
					print("  spec_aiVehicle = nil")
				end

				-- eventListeners length and first few names
				if v.eventListeners ~= nil then
					local cnt = 0
					for _ in pairs(v.eventListeners) do cnt = cnt + 1 end
					print(("  eventListeners count = %d"):format(cnt))
					local c = 0
					for k, _ in pairs(v.eventListeners) do
						if c >= 8 then break end
						print(("    eventListener: %s"):format(tostring(k)))
						c = c + 1
					end
				else
					print("  eventListeners = nil")
				end

				-- print up to 40 top-level fields (name and type) for manual inspection
				local count = 0
				for fk, fv in pairs(v) do
					if count >= 40 then break end
					print(("  FIELD: %s  (type=%s)"):format(tostring(fk), type(fv)))
					count = count + 1
				end
				print("----")
			end
		end
	end)
end

addConsoleCommand("vsfDeepDump", "Deep Dump neighbor/courseplay", "deepDump", VehicleSwitchFilter)

-- VSF_DEEP2: print specializationsByName keys and spec_cpAIImplement contents for neighbour-named enterables
function VehicleSwitchFilter.deepDump2()
	pcall(function()
		if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
			print("VSF_DEEP2: no mission or vehicleSystem")
			return
		end

		local enterables = g_currentMission.vehicleSystem.enterables or {}
		for i, v in ipairs(enterables) do
			local okName, name = pcall(function() return (v.getFullName and v:getFullName()) or "" end)
			name = (okName and tostring(name)) or "<error>"
			local lname = name:lower()
			if lname:find("neigh") or lname:find("neighbor") or lname:find("neighbour") then
				print(("VSF_DEEP2: Index=%d Name=%s"):format(i, name))
				-- specializationsByName keys
				if v.specializationsByName ~= nil then
					print("  specializationsByName keys:")
					for k,_ in pairs(v.specializationsByName) do
						print("    - " .. tostring(k))
					end
				else
					print("  specializationsByName = nil")
				end

				-- spec_cpAIImplement full shallow dump
				if v.spec_cpAIImplement ~= nil then
					print("  spec_cpAIImplement keys/values:")
					local c = 0
					for k,val in pairs(v.spec_cpAIImplement) do
						c = c + 1
						local t = type(val)
						if t == "number" or t == "string" or t == "boolean" then
							print(("    cp.%s = %s"):format(tostring(k), tostring(val)))
						else
							print(("    cp.%s = <%s>"):format(tostring(k), t))
						end	
						if c >= 60 then break end
					end
				else
					print("  spec_cpAIImplement = nil")
				end

				-- also print any mod-specific-looking fields at top-level
				local candidates = {"isNeighbourFieldWorker","isNeighborFieldWorker","neighbourId","neighborId","neighbourName","neighborName"}
				for _, key in ipairs(candidates) do
					local ok, val = pcall(function() return v[key] end)
					print(("  %s = %s"):format(key, tostring(ok and val or "<error>")))
				end

				print("----")
			end
		end
	end)
end

addConsoleCommand("vsfDeepDump2", "Deep Dump2 neighbor/courseplay", "deepDump2", VehicleSwitchFilter)

-- Dump function as a method on VehicleSwitchFilter so addConsoleCommand can call it
function VehicleSwitchFilter._vsf_dumpDisplays()
    -- ensure dbg prints
    VehicleSwitchFilter.debugEnabled = true
    dbg("VSF: Starting display/global scan...")

    for k, v in pairs(_G) do
        if type(k) == "string" then
            local lname = k:lower()
            if lname:find("display") or lname:find("hud") or lname:find("speed") or lname:find("meter") then
                local vt = type(v)
                print(string.format("VSF_DEBUG: Global: %s  (type=%s)", tostring(k), vt))
                if vt == "table" then
                    if v.draw ~= nil then dbg("  has draw()") end
                    if v.gaugeCenterX ~= nil or v.gaugeCenterY ~= nil then
                        dbg(string.format("  gaugeCenterX=%s gaugeCenterY=%s", tostring(v.gaugeCenterX), tostring(v.gaugeCenterY)))
                    end
                    -- print a few fields to help identify the object
                    local count = 0
                    for fk, fv in pairs(v) do
                        if count >= 12 then break end
                        _vsf_printField(tostring(fk), fv)
                        count = count + 1
                    end
                end
            end
        end
    end

    if g_currentMission ~= nil then
        local hud = (g_currentMission.inGameMenu and g_currentMission.inGameMenu.hud) or g_currentMission.hud
        if hud ~= nil then
            print("VSF_DEBUG: g_currentMission.hud found; listing top-level fields:")
            local c = 0
            for fk, fv in pairs(hud) do
                if c >= 30 then break end
                dbg(string.format("  %s = <%s>", tostring(fk), type(fv)))
                c = c + 1
            end
            if hud.speedMeter ~= nil then
                print("VSF_DEBUG: hud.speedMeter exists; fields:")
                local c2 = 0
                for fk, fv in pairs(hud.speedMeter) do
                    if c2 >= 30 then break end
                    dbg(string.format("  %s = <%s>", tostring(fk), type(fv)))
                    c2 = c2 + 1
                end
            else
                dbg("VSF: hud.speedMeter is nil")
            end
        else
            dbg("VSF: g_currentMission.hud not found")
        end
    else
        dbg("VSF: g_currentMission is nil")
    end

    dbg("VSF: display/global scan complete.")
end

-- Register console command bound to the VehicleSwitchFilter table
-- (vsfDumpDisplays already registered in loadMap; addModEventListener below will ensure loadMap runs)
addModEventListener(VehicleSwitchFilter)
