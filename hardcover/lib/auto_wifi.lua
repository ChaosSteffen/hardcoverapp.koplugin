local SETTING = require("hardcover/lib/constants/settings")

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local NetworkMgr = require("ui/network/manager")

-- give up waiting for a connection after this many seconds (NetworkMgr's connectivity check gives up after ~45s)
local CONNECTION_TIMEOUT = 60

local AutoWifi = {
  connection_pending = false,
  disconnect_count = 0,
}
AutoWifi.__index = AutoWifi

function AutoWifi:new(o)
  return setmetatable(o, self)
end

-- Wifi can be enabled without user interaction: either restored in the background (Kobo, Kindle, ...)
-- or toggled directly (PocketBook, ...)
function AutoWifi:canEnableWifi()
  return Device:hasWifiRestore() or Device:hasSeamlessWifiToggle()
end

function AutoWifi:withWifi(callback)
  if NetworkMgr:isWifiOn() then
    callback(false)
    return
  end

  if self.settings:readSetting(SETTING.ENABLE_WIFI)
      and not self.connection_pending
      and not NetworkMgr.pending_connection
      -- someone else (e.g. KOReader restoring wifi on resume) is already connecting, NetworkConnected will follow
      and not NetworkMgr.pending_connectivity_check
      and self:canEnableWifi()
      and G_reader_settings:nilOrFalse("airplanemode") then
    --logger.warn("HARDCOVER enabling wifi")

    local original_on = NetworkMgr.wifi_was_on
    local disconnects_before = self.disconnect_count

    local reset_pending = function()
      self.connection_pending = false

      -- a failed connectivity check clears wifi_was_on, which would stop KOReader from restoring wifi after resume.
      -- It sends no disconnect event, while the user turning wifi off does: keep the user's choice then.
      if not NetworkMgr:isConnected() and self.disconnect_count == disconnects_before then
        NetworkMgr.wifi_was_on = original_on
        G_reader_settings:saveSetting("wifi_was_on", original_on)
      end
    end

    local restore_was_on = function()
      -- connectivity check sets wifi_was_on: keep the user's setting, so KOReader restores wifi after resume
      -- exactly when it would have without us
      NetworkMgr.wifi_was_on = original_on
      G_reader_settings:saveSetting("wifi_was_on", original_on)
    end

    local on_connected = function()
      UIManager:unschedule(reset_pending)
      restore_was_on()
      --logger.warn("HARDCOVER wifi enabled")

      -- Runs outside a coroutine, so API requests block until done and wifi is only disabled afterwards.
      -- connection_pending stays set meanwhile: onNetworkConnected must not start a second, async send.
      local ok, err = pcall(callback, true)
      if not ok then
        logger.warn("Hardcover: network callback failed", err)
      end
      self.connection_pending = false

      -- non-interactive: sends NetworkDisconnected and leaves wifi_was_on alone
      NetworkMgr:disableWifi(restore_was_on)
    end

    self.connection_pending = true
    -- connectivity check never calls back when the connection fails
    UIManager:scheduleIn(CONNECTION_TIMEOUT, reset_pending)

    if Device:hasWifiRestore() then
      NetworkMgr:restoreWifiAsync()
      NetworkMgr:scheduleConnectivityCheck(on_connected)
    else
      NetworkMgr:turnOnWifi(function()
        NetworkMgr:scheduleConnectivityCheck(on_connected)
      end)
    end
  end
end

-- Called on NetworkDisconnecting/NetworkDisconnected
function AutoWifi:onDisconnect()
  self.disconnect_count = self.disconnect_count + 1
end

function AutoWifi:wifiDisableSilent()
  NetworkMgr:turnOffWifi(function()
    -- explicitly disable wifi was on
    NetworkMgr.wifi_was_on = false
    G_reader_settings:saveSetting("wifi_was_on", false)
    --logger.warn("HARDCOVER disabling wifi")
  end)
end

function AutoWifi:wifiPrompt(callback)
  if NetworkMgr:isWifiOn() then
    if callback then
      callback(false)
    end

    return
  end

  if G_reader_settings:isTrue("airplanemode") then
    return
  end

  local network_callback = callback and function() callback(true) end or nil

  if self.settings:readSetting(SETTING.ENABLE_WIFI) then
    NetworkMgr:turnOnWifiAndWaitForConnection(network_callback)
  else
    NetworkMgr:promptWifiOn(network_callback)
  end
end

function AutoWifi:wifiDisablePrompt()
  if self.settings:readSetting(SETTING.ENABLE_WIFI) and self:canEnableWifi() then
    self:wifiDisableSilent()
  else
    NetworkMgr:toggleWifiOff()
  end
end

return AutoWifi
