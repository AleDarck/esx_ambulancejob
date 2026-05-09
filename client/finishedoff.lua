-- ============================================================
-- DETECCIÓN DE REMATE
-- Si el jugador está en fase 'crawl' y recibe daño -> rematado
-- ============================================================

CreateThread(function()
    while true do
        Wait(0)

        -- Solo procesar si estamos en fase crawl
        if isDead and deathPhase == 'crawl' then
            local playerPed = PlayerPedId()

            -- Verificar si el ped recibió daño (fue atacado mientras estaba caído)
            if HasEntityBeenDamagedByAnyPed(playerPed) then
                ClearEntityLastDamageEntity(playerPed)

                -- Notificar al servidor que fue rematado
                TriggerServerEvent('esx_ambulancejob:playerFinishedOff')

                -- Transición local inmediata a fase muerto
                TransitionToDeadPhase()
            end
        end
    end
end)