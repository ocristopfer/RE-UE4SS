-- CI probe: what the release promises a Lua mod on a Linux server. Every step prints one line
--   [ue4ss-ci] <step> PASS|FAIL|INFO <detail>
-- and run_game.py decides from them. Each step is isolated (pcall): a Lua error shows up as a FAIL
-- line instead of hiding the next step. A SIGSEGV still takes the game down - the runner sees that.
local function say(step, status, detail)
  print(string.format("[ue4ss-ci] %s %s %s\n", step, status, tostring(detail or "")))
end

local function step(name, fn)
  local ok, result = pcall(fn)
  if ok then say(name, "PASS", result) else say(name, "FAIL", result) end
  return ok
end

say("lua_started", "PASS", _VERSION)

local native_calls, script_calls, game_thread_calls, new_objects = 0, 0, 0, 0

local function probe()
  step("find_gamestate", function()
    local o = FindFirstOf("GameStateBase")
    assert(o and o:IsValid(), "no GameStateBase")
    return o:GetFullName()
  end)

  step("static_find_object", function()
    local o = StaticFindObject("/Script/Engine.PlayerController:ClientRestart")
    assert(o and o:IsValid(), "PlayerController:ClientRestart not found")
    return o:GetFullName()
  end)

  step("register_hook_native", function()
    local registered = 0
    for _, name in ipairs({
      "/Script/Engine.KismetSystemLibrary:IsValid",
      "/Script/Engine.KismetMathLibrary:Not_PreBool",
      "/Script/Engine.Actor:K2_GetActorLocation",
      "/Script/Engine.PlayerController:ClientRestart",
    }) do
      if pcall(RegisterHook, name, function() native_calls = native_calls + 1 end) then registered = registered + 1 end
    end
    assert(registered > 0, "no native function could be hooked")
    return registered .. " registered"
  end)

  -- The ReceiveTick a Blueprint class implements (the engine calls the derived class's UFunction).
  local ok = pcall(function()
    local seen, n = {}, 0
    for _, actor in ipairs(FindAllOf("Actor") or {}) do
      if n >= 10 then break end
      local cls = actor:GetClass()
      local full = cls:GetFullName()
      if not seen[full] and full:find("/Game/", 1, true) then
        seen[full] = true
        cls:ForEachFunction(function(f)
          if f:GetFName():ToString() == "ReceiveTick" then
            local path = f:GetFullName():gsub("^Function ", "")
            if pcall(RegisterHook, path, function() script_calls = script_calls + 1 end) then n = n + 1 end
          end
        end)
      end
    end
    say("register_hook_blueprint", "INFO", n .. " Blueprint ReceiveTick hooks")
  end)
  if not ok then say("register_hook_blueprint", "FAIL", "error walking Blueprint classes") end

  step("execute_in_game_thread_scheduled", function()
    ExecuteInGameThread(function() game_thread_calls = game_thread_calls + 1 end)
    return "scheduled"
  end)

  step("notify_on_new_object", function()
    NotifyOnNewObject("/Script/Engine.Actor", function() new_objects = new_objects + 1 end)
    return "registered"
  end)

  -- Give the hooks time to fire, then report and say the game is still alive.
  ExecuteWithDelay(30000, function()
    if game_thread_calls > 0 then say("execute_in_game_thread", "PASS", game_thread_calls)
    else say("execute_in_game_thread", "FAIL", "callback never ran") end
    say("hook_calls", "INFO", string.format("native=%d blueprint=%d new_objects=%d", native_calls, script_calls, new_objects))
    say("done", "PASS", "alive")
  end)
end

-- Wait for the map: the GameState exists once the world is up (up to 5 minutes).
local waited = 0
LoopAsync(2000, function()
  waited = waited + 2
  local ok, o = pcall(FindFirstOf, "GameStateBase")
  if (ok and o and o:IsValid()) or waited >= 300 then
    say("world_ready", "INFO", waited .. "s")
    ExecuteWithDelay(5000, probe)
    return true
  end
  return false
end)
