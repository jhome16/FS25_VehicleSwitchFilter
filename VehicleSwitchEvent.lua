-- VehicleSwitchEvent.lua
VehicleSwitchEvent = {}
local VehicleSwitchEvent_mt = Class(VehicleSwitchEvent, Event)

InitEventClass(VehicleSwitchEvent, "VehicleSwitchEvent")

function VehicleSwitchEvent.emptyNew()
    return Event.new(VehicleSwitchEvent_mt)
end

function VehicleSwitchEvent.new(vehicle)
    local self = VehicleSwitchEvent.emptyNew()
    self.vehicle = vehicle
    return self
end

function VehicleSwitchEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
end

function VehicleSwitchEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self:run(connection)
end

function VehicleSwitchEvent:run(connection)
    if not connection:getIsServer() then
        -- This runs on the server when a client sends the event
        if self.vehicle ~= nil and self.vehicle:getIsEnterable() then
            g_currentMission:requestToEnterVehicle(self.vehicle)
        end
    end
end