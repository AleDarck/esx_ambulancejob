local firstSpawn = true
isDead, isSearched, medic = false, false, 0

-- ============================================================
-- VARIABLES DE ESTADO DE MUERTE
-- ============================================================
local deathPhase   = nil   -- 'injured' | 'dead' | nil
local distressSent = false -- Solo se puede mandar UNA vez

-- ============================================================
-- ANIMACIONES
-- Stage 1 (EarlyRespawnTimer): writhe_loop  → herido en el suelo
-- Stage 2 (BleedoutTimer):     dead_a       → tirado muerto/desmayado
-- ============================================================
local INJURED_DICT = "combat@damage@writhe"
local INJURED_ANIM = "writhe_loop"

local DEAD_DICT    = "dead"
local DEAD_ANIM    = "dead_a"

-- ============================================================
-- PLAYER LOADED / LOGOUT / SPAWN
-- ============================================================

RegisterNetEvent('esx:playerLoaded')
AddEventHandler('esx:playerLoaded', function(xPlayer)
  ESX.PlayerLoaded = true
end)

RegisterNetEvent('esx:onPlayerLogout')
AddEventHandler('esx:onPlayerLogout', function()
  ESX.PlayerLoaded = false
  firstSpawn = true
end)

AddEventHandler('esx:onPlayerSpawn', function()
  if firstSpawn then
    firstSpawn = false
    return
  end
  isDead       = false
  deathPhase   = nil
  distressSent = false
  ClearTimecycleModifier()
  SetPedMotionBlur(PlayerPedId(), false)
  ClearExtraTimecycleModifier()
  exports['AX_hud']:hideAllDeath()
end)

-- ============================================================
-- BLIPS DE HOSPITALES
-- ============================================================
CreateThread(function()
  for k, v in pairs(Config.Hospitals) do
    local blip = AddBlipForCoord(v.Blip.coords)
    SetBlipSprite(blip, v.Blip.sprite)
    SetBlipScale(blip, v.Blip.scale)
    SetBlipColour(blip, v.Blip.color)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(TranslateCap('blip_hospital'))
    EndTextCommandSetBlipName(blip)
  end
end)

-- ============================================================
-- BUSQUEDA POR EMS
-- ============================================================
RegisterNetEvent('esx_ambulancejob:clsearch')
AddEventHandler('esx_ambulancejob:clsearch', function(medicId)
  local playerPed = PlayerPedId()
  if isDead then
    local coords = GetEntityCoords(playerPed)
    local playersInArea = ESX.Game.GetPlayersInArea(coords, 50.0)
    for i = 1, #playersInArea do
      if playersInArea[i] == GetPlayerFromServerId(medicId) then
        medic      = tonumber(medicId)
        isSearched = true
        break
      end
    end
  end
end)

-- ============================================================
-- FUNCIONES DE ANIMACION
-- ============================================================

function PlayInjuredAnimation(ped)
  ESX.Streaming.RequestAnimDict(INJURED_DICT, function()
    TaskPlayAnim(ped, INJURED_DICT, INJURED_ANIM,
      1.0, 8.0, -1, 1, -1, false, false, false)
  end)
end

function PlayDeadAnimation(ped)
  ClearPedTasksImmediately(ped)
  ESX.Streaming.RequestAnimDict(DEAD_DICT, function()
    TaskPlayAnim(ped, DEAD_DICT, DEAD_ANIM,
      8.0, -8.0, -1, 1, 0.0, false, false, false)
  end)
end

-- ============================================================
-- FUNCION PRINCIPAL DE MUERTE
-- ============================================================

function OnPlayerDeath()
  ESX.CloseContext()

  isDead       = true
  deathPhase   = 'injured'
  distressSent = false

  local playerPed = PlayerPedId()

  -- Efecto visual rojo
  SetTimecycleModifier("REDMIST_blend")
  SetTimecycleModifierStrength(0.5)
  SetExtraTimecycleModifier("fp_vig_red")
  SetExtraTimecycleModifierStrength(0.8)

  -- Notificar al servidor
  TriggerServerEvent('esx_ambulancejob:setDeathStatus', true)

  -- Resucitar localmente para evitar ragdoll y controlar la animacion
  local coords  = GetEntityCoords(playerPed)
  local heading = GetEntityHeading(playerPed)
  NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, false, false)

-- Congelar posicion e invencibilidad
  FreezeEntityPosition(playerPed, true)
  SetEntityInvincible(playerPed, true)

  -- Activar HUD Stage 1
  local stage1Secs = ESX.Math.Round(Config.EarlyRespawnTimer / 1000)
  exports['AX_hud']:showStage1(stage1Secs)

  -- Reproducir animacion en thread separado para no bloquear
  CreateThread(function()
    Wait(200)
    if isDead and deathPhase == 'injured' then
      PlayInjuredAnimation(playerPed)
    end
  end)

  -- Mantener animacion de herido activa mientras sea fase injured
  CreateThread(function()
    while isDead and deathPhase == 'injured' do
      Wait(500)
      if isDead and deathPhase == 'injured' then
        if not IsEntityPlayingAnim(playerPed, INJURED_DICT, INJURED_ANIM, 3) then
          PlayInjuredAnimation(playerPed)
        end
      end
    end
  end)

  StartDeathTimer()
  StartDistressSignal()
  StartDeathLoop()
end

-- ============================================================
-- TRANSICION INJURED → DEAD
-- Se llama cuando: expira EarlyRespawnTimer O el jugador es rematado
-- ============================================================

function TransitionToDeadPhase()
  if deathPhase == 'dead' then return end
  deathPhase = 'dead'

  local playerPed = PlayerPedId()

  -- Intercambiar pantallas HUD
  exports['AX_hud']:hideStage1()
  local stage2Secs = ESX.Math.Round(Config.BleedoutTimer / 1000)
  exports['AX_hud']:showStage2(stage2Secs)

  -- Cambiar a animacion de muerto
  PlayDeadAnimation(playerPed)

  -- Mantener animacion de muerto activa
  CreateThread(function()
    while isDead and deathPhase == 'dead' do
      Wait(500)
      if isDead and deathPhase == 'dead' then
        if not IsEntityPlayingAnim(playerPed, DEAD_DICT, DEAD_ANIM, 3) then
          PlayDeadAnimation(playerPed)
        end
      end
    end
  end)
end

-- ============================================================
-- LOOP DE MUERTE
-- Deshabilita controles y maneja la busqueda EMS
-- ============================================================

function StartDeathLoop()
  CreateThread(function()
    while isDead do
      DisableAllControlActions(0)
      EnableControlAction(0, 47, true)   -- G  (señal de socorro)
      EnableControlAction(0, 245, true)  -- T  (chat)
      EnableControlAction(0, 38, true)   -- E  (respawn manual)
      EnableControlAction(0, 1, true)    -- Mouse X (girar horizontal)
      EnableControlAction(0, 2, true)    -- Mouse Y (girar vertical)
      EnableControlAction(0, 106, true)  -- Analógico derecho X (gamepad)
      EnableControlAction(0, 107, true)  -- Analógico derecho Y (gamepad)

      -- Reducir sensibilidad del mouse al 30%
      local mouseX = GetControlNormal(0, 1)
      local mouseY = GetControlNormal(0, 2)
      SetControlNormal(0, 1, mouseX * 0.3)
      SetControlNormal(0, 2, mouseY * 0.3)

      if isSearched then
        local playerPed = PlayerPedId()
        local ped = GetPlayerPed(GetPlayerFromServerId(medic))
        isSearched = false
        AttachEntityToEntity(playerPed, ped, 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
        Wait(1000)
        DetachEntity(playerPed, true, false)
        ClearPedTasksImmediately(playerPed)
      end

      Wait(0)
    end
  end)
end

-- ============================================================
-- SEÑAL DE SOCORRO (solo UNA vez, solo en fase injured)
-- ============================================================

function StartDistressSignal()
  CreateThread(function()
    while isDead and not distressSent and deathPhase == 'injured' do
      if IsControlJustReleased(0, 47) then
        SendDistressSignal()
      end
      Wait(0)
    end
  end)
end

function SendDistressSignal()
  if distressSent then return end
  distressSent = true
  ESX.ShowNotification(TranslateCap('distress_sent'))
  TriggerServerEvent('esx_ambulancejob:onPlayerDistress')
end

-- ============================================================
-- TIMERS DE MUERTE
-- Stage 1 → Stage 2, actualiza HUD cada segundo
-- ============================================================

function secondsToClock(seconds)
  if seconds <= 0 then return 0, 0 end
  local hours = string.format('%02.f', math.floor(seconds / 3600))
  local mins  = string.format('%02.f', math.floor(seconds / 60 - (hours * 60)))
  local secs  = string.format('%02.f', math.floor(seconds - hours * 3600 - mins * 60))
  return mins, secs
end

function StartDeathTimer()
  local canPayFine = false

  if Config.EarlyRespawnFine then
    ESX.TriggerServerCallback('esx_ambulancejob:checkBalance', function(canPay)
      canPayFine = canPay
    end)
  end

  local earlySpawnTimer  = ESX.Math.Round(Config.EarlyRespawnTimer / 1000)
  local bleedoutTimerRef = { value = ESX.Math.Round(Config.BleedoutTimer / 1000) }

  -- Thread 1: countdown + update HUD cada segundo
  CreateThread(function()

    -- STAGE 1: EarlyRespawnTimer (fase injured)
    while earlySpawnTimer > 0 and isDead do
      Wait(1000)
      if not isDead then break end
      earlySpawnTimer = earlySpawnTimer - 1
      if deathPhase == 'injured' then
        exports['AX_hud']:updateStage1Timer(earlySpawnTimer)
      end
    end

    -- Transicion a fase muerto al terminar stage 1
    if isDead and deathPhase == 'injured' then
      TransitionToDeadPhase()
    end

    -- STAGE 2: BleedoutTimer (fase dead)
    while bleedoutTimerRef.value > 0 and isDead do
      Wait(1000)
      if not isDead then break end
      bleedoutTimerRef.value = bleedoutTimerRef.value - 1
      if deathPhase == 'dead' then
        exports['AX_hud']:updateStage2Timer(bleedoutTimerRef.value)
      end
    end

    -- Tiempo agotado -> respawn forzado
    if bleedoutTimerRef.value < 1 and isDead then
      RemoveItemsAfterRPDeath()
    end
  end)

  -- Thread 2: input de respawn manual (solo en fase dead)
  CreateThread(function()
    local timeHeld = 0

    -- Esperar a que termine el stage 1
    while earlySpawnTimer > 0 and isDead do
      Wait(500)
    end

    -- Fase muerto: detectar E mantenida para respawn
    while bleedoutTimerRef.value > 0 and isDead do
      Wait(0)

      if deathPhase == 'dead' then
        if not Config.EarlyRespawnFine then
          if IsControlPressed(0, 38) then
            timeHeld = timeHeld + 1
            if timeHeld > 120 then
              RemoveItemsAfterRPDeath()
              break
            end
          else
            timeHeld = 0
          end
        elseif Config.EarlyRespawnFine and canPayFine then
          if IsControlPressed(0, 38) then
            timeHeld = timeHeld + 1
            if timeHeld > 120 then
              TriggerServerEvent('esx_ambulancejob:payFine')
              RemoveItemsAfterRPDeath()
              break
            end
          else
            timeHeld = 0
          end
        end
      end
    end
  end)
end

-- ============================================================
-- RESPAWN
-- ============================================================

function GetClosestRespawnPoint()
  local plyCoords = GetEntityCoords(PlayerPedId())
  local closestDist, closestHospital

  for i = 1, #Config.RespawnPoints do
    local dist = #(plyCoords - Config.RespawnPoints[i].coords)
    if not closestDist or dist <= closestDist then
      closestDist, closestHospital = dist, Config.RespawnPoints[i]
    end
  end

  return closestHospital
end

function RemoveItemsAfterRPDeath()
  TriggerServerEvent('esx_ambulancejob:setDeathStatus', false)

  CreateThread(function()
    ESX.TriggerServerCallback('esx_ambulancejob:removeItemsAfterRPDeath', function()
      local ClosestHospital = GetClosestRespawnPoint()
      ESX.SetPlayerData('loadout', {})

      DoScreenFadeOut(800)
      RespawnPed(PlayerPedId(), ClosestHospital.coords, ClosestHospital.heading)
      while not IsScreenFadedOut() do
        Wait(0)
      end
      DoScreenFadeIn(800)
    end)
  end)
end

function RespawnPed(ped, coords, heading)
  ClearTimecycleModifier()
  ClearExtraTimecycleModifier()
  SetPedMotionBlur(ped, false)

  exports['AX_hud']:hideAllDeath()

  -- Reset ANTES del respawn para cortar todos los loops
  isDead       = false
  deathPhase   = nil
  distressSent = false

  ClearPedTasksImmediately(ped)
  FreezeEntityPosition(ped, false)
  SetEntityInvincible(ped, false)
  SetPlayerInvincible(ped, false)
  ClearPedBloodDamage(ped)

  SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
  NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, true, false)

  TriggerEvent('esx_basicneeds:resetStatus')
  TriggerServerEvent('esx:onPlayerSpawn')
  TriggerEvent('esx:onPlayerSpawn')
  TriggerEvent('playerSpawned')
end

-- ============================================================
-- EVENTOS
-- ============================================================

RegisterNetEvent('esx_ambulancejob:useItem')
AddEventHandler('esx_ambulancejob:useItem', function(itemName)
  ESX.CloseContext()

  local lib       = 'anim@heists@narcotics@funding@gang_idle'
  local anim      = 'gang_chatting_idle01'
  local playerPed = PlayerPedId()

  if itemName == 'medikit' or itemName == 'bandage' then
    ESX.Streaming.RequestAnimDict(lib, function()
      TaskPlayAnim(playerPed, lib, anim, 8.0, -8.0, -1, 0, 0, false, false, false)
      RemoveAnimDict(lib)
      Wait(500)
      while IsEntityPlayingAnim(playerPed, lib, anim, 3) do
        Wait(0)
        DisableAllControlActions(0)
      end
      if itemName == 'medikit' then
        TriggerEvent('esx_ambulancejob:heal', 'big', true)
        ESX.ShowNotification(TranslateCap('used_medikit'))
      else
        TriggerEvent('esx_ambulancejob:heal', 'small', true)
        ESX.ShowNotification(TranslateCap('used_bandage'))
      end
    end)
  end
end)

AddEventHandler('esx:onPlayerDeath', function(data)
  OnPlayerDeath()
end)

-- REMATE: si te atacan en fase injured -> pasa directo a fase dead
RegisterNetEvent('esx_ambulancejob:finishedOff')
AddEventHandler('esx_ambulancejob:finishedOff', function()
  if isDead and deathPhase == 'injured' then
    TransitionToDeadPhase()
  end
end)

RegisterNetEvent('esx_ambulancejob:revive')
AddEventHandler('esx_ambulancejob:revive', function()
  local playerPed = PlayerPedId()
  local coords    = GetEntityCoords(playerPed)
  TriggerServerEvent('esx_ambulancejob:setDeathStatus', false)

  DoScreenFadeOut(800)
  while not IsScreenFadedOut() do
    Wait(50)
  end

  ClearTimecycleModifier()
  ClearExtraTimecycleModifier()
  SetPedMotionBlur(playerPed, false)
  exports['AX_hud']:hideAllDeath()

  isDead       = false
  deathPhase   = nil
  distressSent = false

  local formattedCoords = {
    x = ESX.Math.Round(coords.x, 1),
    y = ESX.Math.Round(coords.y, 1),
    z = ESX.Math.Round(coords.z, 1)
  }

  RespawnPed(playerPed, formattedCoords, 0.0)
  DoScreenFadeIn(800)
end)

RegisterNetEvent('esx_phone:loaded')
AddEventHandler('esx_phone:loaded', function(phoneNumber, contacts)
  local specialContact = {
    name       = 'Ambulance',
    number     = 'ambulance',
    base64Icon = 'data:image/png;base64,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'
  }
  TriggerEvent('esx_phone:addSpecialContact', specialContact.name, specialContact.number, specialContact.base64Icon)
end)

-- Load unloaded IPLs
if Config.LoadIpl then
  RequestIpl('Coroner_Int_on')
end