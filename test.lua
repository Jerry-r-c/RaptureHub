--[[
    EnvLogger v1.0
    Dumps what obfuscated scripts actually DO at runtime.
    
    USAGE:
        loadstring(game:HttpGet("YOUR_RAW_URL"))()
        
        -- paste obfuscated script below this line
        local result = workspace:FindFirstChild("Part")
        ...
    
    OUTPUT:
        A file called "envlog_TIMESTAMP.lua" in your executor workspace folder.
        Also prints to console in real time.
]]

-- ============================================================
--  CONFIGURATION
-- ============================================================
local CONFIG = {
    outputFile    = true,           -- write results to file
    outputConsole = true,           -- print to executor console
    maxDepth      = 3,              -- how deep to serialize tables
    maxTableItems = 12,             -- max items per table
    maxStringLen  = 300,            -- truncate long strings
    hookGame      = true,           -- log game/workspace API calls
    hookGlobals   = true,           -- log global function calls (pcall etc.)
    hookString    = true,           -- log string library calls
    hookMath      = false,          -- log math (very noisy, off by default)
    hookTable     = false,          -- log table library (very noisy)
    captureErrors = true,           -- catch and log runtime errors
}

-- ============================================================
--  INTERNALS
-- ============================================================
local Lines       = {}
local lineCount   = 0
local startTime   = tick()

local rawtype     = typeof or type
local rawtostring = tostring
local rawpcall    = pcall
local rawselect   = select
local rawunpack   = table.unpack or unpack
local rawpairs    = pairs
local rawipairs   = ipairs
local rawsetmt    = setmetatable
local rawgetmt    = getmetatable
local rawformat   = string.format
local rawsub      = string.sub
local rawfind     = string.find
local rawmatch    = string.match
local rawrep      = string.rep
local rawconcat   = table.concat
local rawinsert   = table.insert
local rawlen      = (function() local ok, v = rawpcall(function() return rawlen end) return (ok and v) or function(t) local ok2, n = rawpcall(function() return #t end) return ok2 and n or 0 end end)()

-- safe write: never errors
local function safeWrite(line)
    lineCount = lineCount + 1
    local entry = rawformat("[%05d] %s", lineCount, rawtostring(line))
    rawinsert(Lines, entry)
end

-- ============================================================
--  VALUE SERIALIZER
-- ============================================================
local seen -- forward declare for recursion

local function fmtNum(n)
    if n ~= n then return "0/0" end
    if n == math.huge then return "math.huge" end
    if n == -math.huge then return "-math.huge" end
    return rawformat("%.14g", n)
end

local function fmtString(s)
    if #s > CONFIG.maxStringLen then
        s = rawsub(s, 1, CONFIG.maxStringLen) .. "...[" .. #s .. " bytes]"
    end
    -- use %q but clean it up
    local q = rawformat("%q", s)
    return q
end

local function serialize(val, depth)
    depth = depth or 0
    local t = rawtype(val)

    if t == "nil"      then return "nil" end
    if t == "boolean"  then return rawtostring(val) end
    if t == "number"   then return fmtNum(val) end
    if t == "string"   then return fmtString(val) end

    if t == "function" then
        local info = debug and debug.getinfo and rawpcall(debug.getinfo, val)
        return "function(...) --[[" .. rawtostring(val) .. "]] end"
    end

    if t == "Vector2" then
        return rawformat("Vector2.new(%s, %s)", fmtNum(val.X), fmtNum(val.Y))
    end
    if t == "Vector3" then
        return rawformat("Vector3.new(%s, %s, %s)", fmtNum(val.X), fmtNum(val.Y), fmtNum(val.Z))
    end
    if t == "CFrame" then
        return rawformat("CFrame.new(%s, %s, %s)", fmtNum(val.X), fmtNum(val.Y), fmtNum(val.Z))
    end
    if t == "Color3" then
        return rawformat("Color3.new(%s, %s, %s)", fmtNum(val.R), fmtNum(val.G), fmtNum(val.B))
    end
    if t == "UDim2" then
        return rawformat("UDim2.new(%s,%s,%s,%s)",
            fmtNum(val.X.Scale), fmtNum(val.X.Offset),
            fmtNum(val.Y.Scale), fmtNum(val.Y.Offset))
    end
    if t == "UDim" then
        return rawformat("UDim.new(%s, %s)", fmtNum(val.Scale), fmtNum(val.Offset))
    end
    if t == "EnumItem" then
        return rawtostring(val)
    end
    if t == "Instance" then
        local ok, path = rawpcall(function()
            local parts = {}
            local cur = val
            while cur and cur ~= game do
                rawinsert(parts, 1, cur.Name)
                cur = cur.Parent
            end
            if cur == game then
                rawinsert(parts, 1, "game")
            end
            return rawconcat(parts, ".")
        end)
        return ok and path or ("Instance<" .. rawtostring(val) .. ">")
    end

    if t == "table" then
        if depth >= CONFIG.maxDepth then return "{ ... }" end
        if seen[val] then return "{ --[[cycle]] }" end
        seen[val] = true

        local parts = {}
        local arrayLen = rawpcall(rawlen, val) and #val or 0
        local limit    = math.min(arrayLen, CONFIG.maxTableItems)

        for i = 1, limit do
            rawinsert(parts, serialize(val[i], depth + 1))
        end
        if arrayLen > limit then rawinsert(parts, "...") end

        local keyed = {}
        local keyCount = 0
        local ok2 = rawpcall(function()
            for k, v in rawpairs(val) do
                local isArr = type(k) == "number" and k % 1 == 0 and k >= 1 and k <= arrayLen
                if not isArr then
                    keyCount = keyCount + 1
                    if #keyed < CONFIG.maxTableItems then
                        local ks
                        if type(k) == "string" and rawmatch(k, "^[%a_][%w_]*$") then
                            ks = k
                        else
                            ks = "[" .. serialize(k, depth + 1) .. "]"
                        end
                        rawinsert(keyed, ks .. " = " .. serialize(v, depth + 1))
                    end
                end
            end
        end)
        table.sort(keyed)
        for _, e in rawipairs(keyed) do rawinsert(parts, e) end
        if keyCount > #keyed then rawinsert(parts, "...") end

        seen[val] = nil
        if #parts == 0 then return "{}" end
        return "{ " .. rawconcat(parts, ", ") .. " }"
    end

    return rawtostring(val)
end

local function fmt(val)
    seen = {}
    return serialize(val)
end

local function fmtArgs(...)
    local n   = rawselect("#", ...)
    local out = {}
    for i = 1, n do
        rawinsert(out, fmt(rawselect(i, ...)))
    end
    return rawconcat(out, ", ")
end

-- ============================================================
--  INSTRUMENT (source rewriter — pure Luau, no Lune deps)
-- ============================================================
local Instrument = {}

local tracedNamespaces = {
    Axes=true, BrickColor=true, CFrame=true, Color3=true,
    ColorSequence=true, ColorSequenceKeypoint=true, Faces=true,
    Font=true, NumberRange=true, NumberSequence=true,
    NumberSequenceKeypoint=true, OverlapParams=true, PhysicalProperties=true,
    Random=true, Ray=true, RaycastParams=true, Rect=true,
    Region3=true, TweenInfo=true, UDim=true, UDim2=true,
    Vector2=true, Vector3=true, vector=true,
}

local function safeSuffix(v)
    return v:match("^%s*;?%s*$") ~= nil or v:match("^%s*;?%s*%-%-") ~= nil
end

local function scanLongBrackets(line, current)
    local protected = current ~= nil
    local position  = 1
    if current ~= nil then
        local closing = "]" .. current .. "]"
        local closeAt = line:find(closing, 1, true)
        if closeAt == nil then return current, true end
        position = closeAt + #closing
        current  = nil
    end
    while position <= #line do
        local ch = line:sub(position, position)
        if ch == '"' or ch == "'" then
            local q = ch; position = position + 1
            while position <= #line do
                local inner = line:sub(position, position)
                if inner == "\\" then position = position + 2
                elseif inner == q then position = position + 1; break
                else position = position + 1 end
            end
        elseif line:sub(position, position + 1) == "--" then
            local opening = line:sub(position + 2):match("^%[(=*)%[")
            if opening == nil then break end
            protected     = true
            local closing = "]" .. opening .. "]"
            local closeAt = line:find(closing, position + #opening + 4, true)
            if closeAt == nil then return opening, true end
            position = closeAt + #closing
        elseif ch == "[" then
            local opening = line:sub(position):match("^%[(=*)%[")
            if opening == nil then position = position + 1
            else
                protected     = true
                local closing = "]" .. opening .. "]"
                local closeAt = line:find(closing, position + #opening + 2, true)
                if closeAt == nil then return opening, true end
                position = closeAt + #closing
            end
        else position = position + 1 end
    end
    return current, protected
end

local function tracedExpression(val)
    if val:match("^[%a_][%w_%.]*:[%a_][%w_]*%b()$") then return true end
    if val:match("^game:GetService%b()$") then return true end
    if val:match("^gethui%b()$") or val:match("^settings%b()$") then return true end
    if val:match("^game%.[%a_][%w_%.]*$") or val:match("^workspace%.[%a_][%w_%.]*$") then return true end
    local ns = val:match("^([%a_][%w_]*)%.[%a_][%w_]*%b()$")
    if ns and tracedNamespaces[ns] then return true end
    return false
end

local hotLocalPatterns = {
    "^%s*os%.clock%s*%(", "^%s*DateTime%.", "^%s*math%.", "^%s*string%.",
    "^%s*bit32%.", "^%s*buffer%.", "^%s*coroutine%.", "^%s*task%.",
    "^%s*pcall%s*%(", "^%s*xpcall%s*%(", "^%s*collectgarbage%s*%(",
}

local function splitLineComment(value)
    local quote, position = nil, 1
    while position <= #value do
        local ch = value:sub(position, position)
        if quote then
            if ch == "\\" then position = position + 2
            elseif ch == quote then quote = nil; position = position + 1
            else position = position + 1 end
        elseif ch == '"' or ch == "'" then quote = ch; position = position + 1
        elseif value:sub(position, position + 1) == "--" then
            return value:sub(1, position - 1), value:sub(position)
        else position = position + 1 end
    end
    return value, ""
end

local function completeSingleLineExpression(value)
    local stack, pairs_, quote, position = {}, {[")"]=true,["}"]=true,"]"=true}, nil, 1
    while position <= #value do
        local ch = value:sub(position, position)
        if quote then
            if ch == "\\" then position = position + 2
            elseif ch == quote then quote = nil; position = position + 1
            else position = position + 1 end
        elseif ch == '"' or ch == "'" then quote = ch; position = position + 1
        elseif ch == "(" or ch == "[" or ch == "{" then
            stack[#stack + 1] = ch; position = position + 1
        elseif pairs_[ch] then
            if #stack == 0 then return false end
            stack[#stack] = nil; position = position + 1
        else position = position + 1 end
    end
    if quote or #stack ~= 0 then return false end
    local last = value:match("(%S)%s*$")
    if not last then return false end
    local ops = {[","]=true,["+"]=true,["-"]=true,["*"]=true,["/"]=true,
                 ["%"]=true,["^"]=true,["="]=true,["<"]=true,[">"]=true,
                 ["~"]=true,["."]=true,[":"]=true}
    return not ops[last]
end

local function generalLocalExpression(line, remainder)
    if #line > 1000 then return nil end
    local _, localCount = line:gsub("%f[%a]local%f[%A]", "")
    if localCount ~= 1 then return nil end
    local expression, comment = splitLineComment(remainder)
    local body, semicolon = expression:match("^(.-)(%s*;%s*)$")
    local suffix = comment ~= "" and (" " .. comment) or ""
    if body then expression = body; suffix = semicolon .. suffix end
    expression = expression:gsub("^%s+", ""):gsub("%s+$", "")
    if expression == "" or expression:find(";", 1, true) then return nil end
    if expression:find("`", 1, true) then return nil end
    if not completeSingleLineExpression(expression) then return nil end
    for _, ending in rawipairs({"then","else","do","and","or","not","if","return"}) do
        if expression:match("%f[%a]" .. ending .. "%f[%A]%s*$") then return nil end
    end
    if expression:match("^function%f[%A]") then return nil end
    for _, pattern in rawipairs(hotLocalPatterns) do
        if expression:match(pattern) then return nil end
    end
    return expression, suffix
end

local function transformLine(line, lineNumber)
    -- const → local
    local cI, cN, cEq = line:match("^(%s*)const%s+([%a_][%w_]*)(%s*=)")
    if cI then
        line = cI .. "local " .. cN .. cEq .. line:sub(#cI + #"const" + 1 + #cN + #cEq + 1)
    end

    -- Instance.new with name
    local nI, lN, args, suf = line:match("^(%s*)local%s+([%a_][%w_]*)%s*=%s*Instance%.new(%b())(.*)$")
    if nI and safeSuffix(suf) then
        local inner    = args:sub(2, -2)
        local sep      = inner:match("^%s*$") and "" or ", "
        return nI .. "local " .. lN .. " = __el_namedInst(" .. rawformat("%q", lN) .. sep .. inner .. ")" .. suf
    end

    -- Traced call expressions
    local cI2, cN2, expr, suf2 = line:match("^(%s*)local%s+([%a_][%w_]*)%s*=%s*([%a_][%w_%.:]*%b())(.*)$")
    if cI2 and safeSuffix(suf2) and tracedExpression(expr) then
        return cI2 .. "local " .. cN2 .. " = __el_trace(" .. rawformat("%q", cN2) .. ", " .. lineNumber .. ", " .. expr .. ")" .. suf2
    end

    -- Traced property access
    local pI, pN, pExpr, pSuf = line:match("^(%s*)local%s+([%a_][%w_]*)%s*=%s*([%a_][%w_%.]*)(.*)$")
    if pI and safeSuffix(pSuf) and tracedExpression(pExpr) then
        return pI .. "local " .. pN .. " = __el_trace(" .. rawformat("%q", pN) .. ", " .. lineNumber .. ", " .. pExpr .. ")" .. pSuf
    end

    -- General local
    local gI, gN, gRem = line:match("^(%s*)local%s+([%a_][%w_]*)%s*=%s*(.+)$")
    if gI then
        local gExpr, gSuf = generalLocalExpression(line, gRem)
        if gExpr then
            return gI .. "local " .. gN .. " = __el_trace(" .. rawformat("%q", gN) .. ", " .. lineNumber .. ", " .. gExpr .. ")" .. (gSuf or "")
        end
    end

    return line
end

local function opaqueSource(source)
    local lineCount2, longestLine = 0, 0
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lineCount2 = lineCount2 + 1
        if #line > longestLine then longestLine = #line end
    end
    if longestLine > 1000 then return true end
    if #source >= 4096 and lineCount2 <= 24 then return true end
    if #source >= 4096 then
        local _, semis = source:gsub(";", "")
        if semis > lineCount2 * 8 then return true end
        local _, escaped = source:gsub("\\%d%d%d", "")
        if escaped >= 32 then return true end
    end
    return false
end

function Instrument.transform(source)
    if opaqueSource(source) then
        safeWrite("-- [EnvLogger] source is opaque/minified, skipping transform (API hooks still active)")
        return source
    end
    local output      = {}
    local longBracket = nil
    local lineNumber  = 0
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lineNumber = lineNumber + 1
        local protected2
        longBracket, protected2 = scanLongBrackets(line, longBracket)
        if protected2 then
            rawinsert(output, line)
        else
            rawinsert(output, transformLine(line, lineNumber))
        end
    end
    return rawconcat(output, "\n")
end

-- ============================================================
--  HOOK ENGINE
-- ============================================================
local hooked = {} -- track what we already wrapped

local function makeHook(name, original)
    if type(original) ~= "function" then return original end
    return function(...)
        local args = fmtArgs(...)
        local results = table.pack(rawpcall(original, ...))
        if not results[1] then
            safeWrite(rawformat("-- ERROR in %s(%s): %s", name, args, rawtostring(results[2])))
            error(results[2], 2)
        end
        local retParts = {}
        for i = 2, results.n do
            rawinsert(retParts, fmt(results[i]))
        end
        local retStr = rawconcat(retParts, ", ")
        if retStr ~= "" then
            safeWrite(rawformat("local _ = %s(%s) --> %s", name, args, retStr))
        else
            safeWrite(rawformat("%s(%s)", name, args))
        end
        return rawunpack(results, 2, results.n)
    end
end

-- ============================================================
--  ENVIRONMENT BUILDER
-- ============================================================
local function buildEnv(baseEnv)
    local env = {}

    -- Copy everything from the base environment
    for k, v in rawpairs(baseEnv) do
        env[k] = v
    end

    -- Inject trace helpers
    env.__el_trace = function(name, line, value)
        safeWrite(rawformat("-- line %d: local %s = %s", line, name, fmt(value)))
        return value
    end

    env.__el_namedInst = function(name, ...)
        local inst = Instance.new(...)
        safeWrite(rawformat("local %s = Instance.new(%s) --> %s", name, fmtArgs(...), fmt(inst)))
        return inst
    end

    -- Hook global functions
    if CONFIG.hookGlobals then
        local globalsToHook = {
            "warn", "error", "assert",
            "loadstring", "require",
            "collectgarbage", "gcinfo",
            "newproxy", "setfenv",
        }
        for _, name in rawipairs(globalsToHook) do
            local orig = env[name] or _G[name]
            if orig then
                env[name] = makeHook(name, orig)
            end
        end

        -- hook getfenv specially: when obfuscated script calls getfenv()
        -- inject our hooks into whatever env it returns
        local origGetfenv = getfenv
        env.getfenv = function(n)
            local e2 = origGetfenv(n or 1)
            if type(e2) == "table" then
                -- inject key hooks into the returned env
                e2.print   = makeHook("print", rawpcall and print or e2.print)
                e2.warn    = makeHook("warn", e2.warn or warn)
                e2.require = e2.require and makeHook("require", e2.require)
                e2.loadstring = e2.loadstring and makeHook("loadstring", e2.loadstring)
            end
            return e2
        end
    end

    -- Hook string library
    if CONFIG.hookString then
        local strLib = {}
        for k, v in rawpairs(string) do
            if type(v) == "function" then
                strLib[k] = makeHook("string." .. k, v)
            else
                strLib[k] = v
            end
        end
        env.string = strLib
    end

    -- Hook math library
    if CONFIG.hookMath then
        local mathLib = {}
        for k, v in rawpairs(math) do
            if type(v) == "function" then
                mathLib[k] = makeHook("math." .. k, v)
            else
                mathLib[k] = v
            end
        end
        env.math = mathLib
    end

    -- Hook table library
    if CONFIG.hookTable then
        local tableLib = {}
        for k, v in rawpairs(table) do
            if type(v) == "function" then
                tableLib[k] = makeHook("table." .. k, v)
            else
                tableLib[k] = v
            end
        end
        env.table = tableLib
    end

    -- Hook game/workspace via __index metamethod
    if CONFIG.hookGame then
        if hookmetamethod then
            local oir
            local handler = function(self, key)
                local val = oir(self, key)
                if type(val) == "function" then
                    return makeHook(rawtostring(self) .. "." .. rawtostring(key), val)
                end
                safeWrite(rawformat("-- game.%s --> %s", rawtostring(key), fmt(val)))
                return val
            end
            local ok2, err2 = rawpcall(function()
                oir = hookmetamethod(game, "__index",
                    newcclosure and newcclosure(handler) or handler)
            end)
            if not ok2 then
                safeWrite("-- [EnvLogger] hookmetamethod failed: " .. rawtostring(err2))
            end
        else
            safeWrite("-- [EnvLogger] hookmetamethod not available on this executor")
        end
    end

    -- pcall / xpcall wrappers that still log errors
    local origPcall  = rawpcall
    local origXpcall = xpcall
    env.pcall = function(fn, ...)
        local results = table.pack(origPcall(fn, ...))
        if not results[1] then
            safeWrite(rawformat("-- pcall caught: %s", rawtostring(results[2])))
        end
        return rawunpack(results, 1, results.n)
    end
    env.xpcall = function(fn, handler, ...)
        return origXpcall(fn, function(err)
            safeWrite(rawformat("-- xpcall caught: %s", rawtostring(err)))
            return handler(err)
        end, ...)
    end

    -- HttpGet / HttpPost logging
    local function wrapHttp(obj)
        if type(obj) ~= "table" and type(obj) ~= "userdata" then return obj end
        local wrapped = {}
        rawsetmt(wrapped, {
            __index = function(_, key)
                local val = obj[key]
                if type(val) == "function" then
                    return function(self, url, ...)
                        safeWrite(rawformat("HttpService:%s(%q, ...)", key, rawtostring(url)))
                        return val(obj, url, ...)
                    end
                end
                return val
            end
        })
        return wrapped
    end

    -- Expose HttpService logs
    rawpcall(function()
        local hs = game:GetService("HttpService")
        env.httpService = wrapHttp(hs)
    end)

    return env
end

-- ============================================================
--  OUTPUT
-- ============================================================
local function flush()
    local header = rawformat([[
--[[
    EnvLogger Output
    Generated: %s
    Lines captured: %d
    Duration: %.3fs
--]]
]], os.date and os.date() or "unknown", #Lines, tick() - startTime)

    local body = header .. rawconcat(Lines, "\n")

    -- always copy to clipboard
    rawpcall(setclipboard, body)
    rawpcall(writefile, rawformat("envlog_%d.lua", math.floor(tick())), body)
    print("[EnvLogger] Done! " .. #Lines .. " lines captured. Output copied to clipboard.")

    return body
end

-- ============================================================
--  MAIN LOADER
-- ============================================================
local EnvLogger = {}

function EnvLogger.run(source)
    safeWrite("-- [EnvLogger] Starting capture")
    safeWrite(rawformat("-- [EnvLogger] Source length: %d bytes", #source))
    safeWrite("-- =============================================")

    -- 1. Transform source to inject local-variable tracing
    local transformed = Instrument.transform(source)

    -- 2. Build sandboxed environment on top of the real _G
    local env = buildEnv(_G)

    -- 3. Compile
    local fn, err = loadstring(transformed)
    if not fn then
        -- Compilation failed on transformed; try original
        fn, err = loadstring(source)
        if not fn then
            safeWrite("-- [EnvLogger] COMPILE ERROR: " .. rawtostring(err))
            flush()
            return
        end
        safeWrite("-- [EnvLogger] Transform failed compile, running original")
    end

    -- 4. Set environment
    -- Try setfenv, but also patch _G directly so upvalue-based obfuscators see hooks
    rawpcall(setfenv, fn, env)
    for k, v in rawpairs(env) do
        rawpcall(function() _G[k] = v end)
    end

    -- 5. Run with error capture
    -- Pass the standard varargs obfuscated scripts expect:
    -- setmetatable, newproxy, {...}, unpack, getmetatable, _ENV/getfenv(), select
    safeWrite("-- [EnvLogger] Running script...")
    safeWrite("-- =============================================")

    local ok, runErr = rawpcall(fn,
        setmetatable,
        newproxy,
        {},
        table.unpack or unpack,
        getmetatable,
        getfenv and getfenv() or _ENV,
        select
    )

    safeWrite("-- =============================================")
    if ok then
        safeWrite("-- [EnvLogger] Script finished cleanly")
    else
        safeWrite("-- [EnvLogger] Runtime error: " .. rawtostring(runErr))
    end

    flush()
end

-- ============================================================
--  INJECT GLOBAL SO USER CODE BELOW WORKS
-- ============================================================
-- After loadstring(URL)(), the user puts their obfuscated script
-- below. We intercept it by overwriting loadstring globally.

local _originalLoadstring = loadstring

-- Store reference so the below-code usage works
_G.__envlogger = EnvLogger

-- Monkey-patch: any loadstring call AFTER this runs through the logger
local alreadyIntercepted = false
getfenv(0).loadstring = function(src, chunkname)
    if alreadyIntercepted then
        return _originalLoadstring(src, chunkname)
    end
    -- This is the user's obfuscated script
    alreadyIntercepted = true
    return function(...)
        EnvLogger.run(src)
    end
end

-- Also expose a direct API for explicit usage:
--   __envlogger.run(source_string)
_G.__envlogger = EnvLogger

print("[EnvLogger] Loaded. Paste your obfuscated script below, or use:")
print("  __envlogger.run(source)")
print("  loadstring(game:HttpGet('YOUR_SCRIPT_URL'))()")
