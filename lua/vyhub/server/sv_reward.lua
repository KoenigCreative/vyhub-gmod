VyHub.Reward = VyHub.Reward or {}
VyHub.Reward.executed_rewards_queue = VyHub.Reward.executed_rewards_queue or {}
VyHub.Reward.executed_rewards = VyHub.Reward.executed_rewards or {}
VyHub.rewards = VyHub.rewards or {}

local RewardEvent = {
    DIRECT = "DIRECT",
    CONNECT = "CONNECT",
    SPAWN = "SPAWN",
    DEATH = "DEATH",
    DISCONNECT = "DISCONNECT",
    DISABLE = "DISABLE",
}

local RewardType = {
    COMMAND = "COMMAND",
    SCRIPT = "SCRIPT",
    CREDITS = "CREDITS",
    MEMBERSHIP = "MEMBERSHIP",
}

function VyHub.Reward:refresh(callback)
    local user_ids = ""

    for _, ply in pairs(player.GetHumans()) do
        if IsValid(ply) then
            local id = ply:VyHubID()

            if id != nil then
                local glue = '&'

                if user_ids == "" then
                    glue = '?'
                end

                user_ids = user_ids .. glue .. 'user_id=' .. id
            end
        end
    end

    if user_ids == "" then
        VyHub.rewards = {}
    else
        VyHub.API:get('/packet/reward/applied/user' .. user_ids, nil, 
        { active = "true", serverbundle_id = VyHub.server.serverbundle.id, status = "OPEN",
          for_server_id = VyHub.server.id, foreign_ids = "true"}, 
        function(code, result)
            VyHub.rewards = result
            VyHub:msg(f("Found %i users with open rewards.", table.Count(result)), "debug")

            if callback then
                callback()
            end
        end, function (code, reason)
            
        end)
    end
end

function VyHub.Reward:set_executed(reward_id)
    table.insert(VyHub.Reward.executed_rewards, reward_id)
    table.insert(VyHub.Reward.executed_rewards_queue, reward_id)

    VyHub.Reward:save_executed()
end

function VyHub.Reward:save_executed()
    VyHub.Cache:save("executed_rewards_queue", VyHub.Reward.executed_rewards_queue)
end

function VyHub.Reward:send_executed()
    for i, reward_id in pairs(VyHub.Reward.executed_rewards) do
        VyHub.API:patch('/packet/reward/applied/%s', { reward_id }, { executed_on = { VyHub.server.id } }, function (code, result)
            VyHub.Reward.executed_rewards_queue[i] = nil
            VyHub.Reward:save_executed()
        end, function (code, reason)
            if code >= 400 and code < 500 then
                VyHub:msg(f("Could not mark reward %s as executed. Aborting.", reward_id), "error")
                VyHub.Reward.executed_rewards_queue[i] = nil
                VyHub.Reward:save_executed()
            end
        end)
    end
end

function VyHub.Reward:exec_rewards(event, steamid)
    steamid = steamid or nil

    local allowed_events = { event }

    local rewards_by_player = VyHub.rewards

    if steamid != nil then
        rewards_by_player = {}
        rewards_by_player[steamid] = VyHub.rewards[steamid]
    else
        if event != RewardEvent.DIRECT then
            return
        end
    end

    if event == RewardEvent.DIRECT then
        table.insert(allowed_events, RewardEvent.DISABLE)
    end

    for steamid, arewards in pairs(rewards_by_player) do
        local ply = player.GetBySteamID64(steamid)

        if not IsValid(ply) then
            VyHub:msg(f("Player %s not valid, skipping.", steamid), "debug")
            continue 
        end

        for _, areward in pairs(arewards) do
            local se = true
            local reward = areward.reward

            if not table.HasValue(allowed_events, event) then
                continue
            end

            if table.HasValue(VyHub.Reward.executed_rewards, areward.id) then
                VyHub:msg(f("Skipped reward %s, because it already has been executed.", areward.id), "debug")
                continue
            end

            local data = reward.data

            if reward.type == RewardType.COMMAND then
                if data.command != nil then
                    local cmd = VyHub.Reward:do_string_replacements(data.command, ply, areward)
                    game.ConsoleCommand(cmd.. "\n")
                end
            elseif reward.type == RewardType.SCRIPT then

            else
                VyHub:msg(f("No implementation for reward type %s", reward.type) "warning")
            end

            VyHub:msg(f("Executed reward %s for user %s (%s): %s", reward.type, ply:Nick(), ply:SteamID64(), json.encode(data)))

            if se and reward.once then
                VyHub.Reward:set_executed(areward.id)
            end
        end
    end

    VyHub.Reward:send_executed()
end

function VyHub.Reward:do_string_replacements(inp_str, ply, areward)
    local replacements = {
        ["user_id"] = ply:VyHubID(), 
        ["nick"] = ply:Nick(), 
        ["steamid64"] = ply:SteamID64(), 
        ["steamid32"] = ply:SteamID(), 
        ["uniqueid"] = ply:UniqueID(), 
        ["applied_packet_id"] = areward.applied_packet_id, 
    }

    for k, v in pairs(replacements) do
        inp_str = string.Replace(tostring(inp_str), "%" .. tostring(k) .. "%", tostring(v))
    end

    return inp_str
end

hook.Add("vyhub_ready", "vyhub_reward_vyhub_ready", function ()
    VyHub.Reward.executed_rewards_queue = VyHub.Cache:get("executed_rewards_queue") or {}

    VyHub.Reward:refresh(function ()
        VyHub.Reward:exec_rewards(RewardEvent.DIRECT)
    end)

    timer.Create("vyhub_reward_refresh", 60, 0, function ()
        VyHub.Reward:refresh(function ()
            VyHub.Reward:exec_rewards(RewardEvent.DIRECT)
        end)
    end)

    hook.Add("vyhub_ply_initialized", "vyhub_reward_vyhub_ply_initialized", function(ply)
		VyHub.Reward:exec_rewards(RewardEvent.CONNECT, ply:SteamID64())
		hook.Call("vyhub_reward_post_connect", _, ply)
	end)

	hook.Add("PlayerSpawn", "vyhub_reward_PlayerSpawn", function(ply) 
		if ply:Alive() then
			VyHub.Reward:exec_rewards(ply, RewardEvent.SPAWN, ply:SteamID64())
		end
	end)

    hook.Add("PostPlayerDeath", "vyhub_reward_PostPlayerDeath", function(ply)
        VyHub.Reward:exec_rewards(ply, RewardEvent.DEATH, ply:SteamID64())
	end)

    hook.Add("PlayerDisconnect", "vyhub_reward_PlayerDisconnect", function(ply)
		if IsValid(ply) then
			VyHub.Reward:exec_rewards(ply, RewardEvent.Disconnect, ply:SteamID64())
		end
	end)
end)