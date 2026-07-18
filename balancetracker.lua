-- Balance Tracker v3.2 FINAL (полный, с /bpay и /bpere)

local script_name = "BalanceTracker"
local this_script = script.this
local sampev = require 'lib.samp.events'

local BASE_DIR = getGameDirectory() .. "\\moonloader\\BalanceTracker\\"
local config_path = BASE_DIR .. "data.json"
local json = require 'json'

local function get_week_key(t)
    return string.format("%04d_%02d_%d", t.year, t.month, math.floor((t.day - 1) / 7) + 1)
end

local function get_today()
    local t = os.date("*t")
    return string.format("%02d.%02d.%04d", t.day, t.month, t.year)
end

local function load_json(path)
    local file = io.open(path, "r")
    if file then local c = file:read("*a"); file:close(); if c and #c > 0 then local ok, d = pcall(json.decode, c); if ok then return d end end end
    return nil
end

local function save_json(path, tbl)
    local file = io.open(path, "w")
    if file then file:write(json.encode(tbl)); file:close() end
end

local function save_data()
    if not data then return end
    save_json(config_path, {
        balances = data.balances, current_server = data.current_server,
        server_ips = data.server_ips, exchange_rates = data.exchange_rates,
        day_start = data.day_start, transfers_count = data.transfers_count or 0,
        pays_count = data.pays_count or 0
    })
end

local function load_week_file(prefix, week_key)
    return load_json(BASE_DIR .. prefix .. "_" .. week_key .. ".json") or {}
end

local function save_week_file(prefix, week_key, tbl)
    save_json(BASE_DIR .. prefix .. "_" .. week_key .. ".json", tbl)
end

local function get_current_week()
    return get_week_key(os.date("*t"))
end

local function get_available_weeks(prefix)
    local weeks = {}
    for month_offset = 0, 11 do
        local t = os.date("*t"); t.month = t.month - month_offset
        local dt = os.date("*t", os.time(t))
        for week = 1, 5 do
            local key = string.format("%04d_%02d_%d", dt.year, dt.month, week)
            if doesFileExist(BASE_DIR .. prefix .. "_" .. key .. ".json") then
                table.insert(weeks, { key = key, year = dt.year, month = dt.month, week = week })
            end
        end
    end
    table.sort(weeks, function(a, b) return a.key > b.key end)
    return weeks
end

local function get_adjacent_week(current_key, dir)
    local y, m, w = current_key:match("(%d+)%_(%d+)_(%d+)"); y, m, w = tonumber(y), tonumber(m), tonumber(w)
    if dir == "next" then w = w + 1; if w > 5 then m = m + 1; w = 1 end; if m > 12 then y = y + 1; m = 1 end
    else w = w - 1; if w < 1 then m = m - 1; w = 5 end; if m < 1 then y = y - 1; m = 12 end end
    return string.format("%04d_%02d_%d", y, m, w)
end

if not data then data = {} end
local saved = load_json(config_path)
for k, v in pairs({ balances = {}, current_server = nil, server_ips = {}, exchange_rates = {}, day_start = {}, transfers_count = 0, pays_count = 0 }) do
    if saved and saved[k] ~= nil then data[k] = saved[k] else data[k] = v end
end

local balances, current_server, server_ips, exchange_rates, day_start = data.balances, data.current_server, data.server_ips, data.exchange_rates, data.day_start
if not data.unread_transfers then data.unread_transfers = false end
if not data.unread_pays then data.unread_pays = false end
if not data.transfers_count then data.transfers_count = 0 end
if not data.pays_count then data.pays_count = 0 end

local history_cache, transfers_cache, pays_cache = {}, {}, {}
local current_history_week, current_transfers_week, current_pays_week = nil, nil, nil
local stats_pending, stats_callback = false, nil
local payday_detected, payday_timer = false, 0

local CSA, CVC = ':CASH:', ':CASHV:'
local NEW_BAL = function() return { sa = { cash = 0, bank = 0, personal = 0, deposit = 0 }, vc = { cash = 0, bank = 0, deposit = 0 }, az = 0, btc = 0, euro = 0, asc = 0, eth = 0, ltc = 0 } end

local function extract_money(s)
    if not s then return 0 end
    if type(s) ~= "string" then return 0 end
    local clean = s:gsub('[^%d]', '')
    if clean == "" then return 0 end
    return tonumber(clean) or 0
end

local function format_money(n)
    local s = tostring(n):reverse():gsub("(%d%d%d)", "%1."):reverse()
    if s:sub(1,1) == '.' then s = s:sub(2) end
    return s
end

local function format_diff(d, c)
    local C = c or CSA
    if d > 0 then return string.format("{33AA33}+%s%s", C, format_money(d))
    elseif d < 0 then return string.format("{FF6347}%s%s", C, format_money(-d))
    else return "" end
end

local function format_diff_int(d)
    if d > 0 then return string.format("{33AA33}+%d", d)
    elseif d < 0 then return string.format("{FF6347}%d", d)
    else return "" end
end

local function is_all_zero(tbl)
    if type(tbl) ~= "table" then return true end
    for _, v in pairs(tbl) do
        if type(v) == "number" and v ~= 0 then return false end
        if type(v) == "table" and not is_all_zero(v) then return false end
    end
    return true
end

local function get_bal()
    if current_server then
        if not balances[current_server] then balances[current_server] = NEW_BAL() end
        return balances[current_server]
    end
    if not balances["__pending__"] then balances["__pending__"] = NEW_BAL() end
    return balances["__pending__"]
end

local function get_server_name() return current_server or "?" end

local function get_server_icon()
    if not current_server then return ":?:"
    elseif current_server == "Vice City" or current_server:find("VC") then return ":VC:"
    else return ":ARZ:" end
end

local function is_vc() return current_server and (current_server == "Vice City" or current_server:find("VC")) end

local function rate_color(ds)
    if not ds then return "{888888}" end
    local today = get_today()
    if ds == today then return "{FFFFFF}" end
    local function pd(s)
        local d, m, y = s:match("(%d%d)%.(%d%d)%.(%d%d%d%d)")
        return d and os.time({ day = tonumber(d), month = tonumber(m), year = tonumber(y) })
    end
    local tr, tt = pd(ds), pd(today)
    if not tr or not tt then return "{888888}" end
    local days = math.floor((tt - tr) / 86400)
    if days <= 1 then return "{AAAAAA}" elseif days <= 3 then return "{777777}" elseif days <= 7 then return "{444444}" else return "{222222}" end
end

local function save_balance_to_history()
    local bal = get_bal()
    local today = get_today()
    local sk = current_server or "__pending__"
    local wk = get_current_week()
    local hist = load_week_file("history", wk)
    if not hist[sk] then hist[sk] = {} end
    hist[sk][today] = {
        sa = { bal.sa.cash, bal.sa.bank, bal.sa.personal, bal.sa.deposit },
        vc = { bal.vc.cash, bal.vc.bank or 0, bal.vc.deposit },
        az = bal.az, bt = bal.btc, eu = bal.euro, as = bal.asc, et = bal.eth, lt = bal.ltc
    }
    save_week_file("history", wk, hist)
    history_cache[wk] = hist
end

local function parse_rates_dialog(text)
    local t = text:gsub("%s", "")
    local rates, bal = { date = get_today() }, get_bal()
    local br = t:match('Bitcoin%(BTC%)::CASH:(%d[%d%.]*)')
    local bh = t:match('%[Увасесть:(%d+)BTC%]')
    if br then rates.btc_rate = extract_money(br) end
    if bh then bal.btc = tonumber(bh) or bal.btc end
    local lr = t:match('Litecoin%(LTC%):[^{]*:CASH:(%d[%d%.]*)')
    if lr then rates.ltc_rate = extract_money(lr) end
    local er = t:match('Ethereum%(ETH%):[^{]*:CASH:(%d[%d%.]*)')
    if er then rates.eth_rate = extract_money(er) end
    local ar = t:match('ArizonaCoin%(ASC%)::CASH:(%d[%d%.]*)')
    local ah = t:match('%[Увасесть:(%d+)ASC%]')
    if ar then rates.asc_rate = extract_money(ar) end
    if ah then bal.asc = tonumber(ah) or 0 end
    local eur = t:match('ЕВРО%(euro%)::CASH:(%d[%d%.]*)')
    if eur then rates.euro_rate = extract_money(eur) end
    if br or ar or eur then exchange_rates[rates.date] = rates; save_data() end
end

local function detect_server_from_exchange(text)
    local t = text:gsub("%s", "")
    local name = t:match('Сервер,накоторомВынаходитесьсейчас:{ae433d}([%a]+)') or t:match('Сервер,накоторомВынаходитесьсейчас:[^{]*([%a]+)')
    if name then
        local ip = sampGetCurrentServerAddress() or ""
        if ip ~= "" then server_ips[ip] = name end
        if current_server ~= name then
            if balances["__pending__"] then balances[name] = balances["__pending__"]; balances["__pending__"] = nil end
            if day_start["__pending__"] then day_start[name] = day_start["__pending__"]; day_start["__pending__"] = nil end
            current_server = name; data.current_server = name; save_data()
            sampAddChatMessage(string.format('[BalanceTracker] Сервер определён: %s %s', get_server_icon(), name), 0xFFD700)
        end
    end
end

local function parse_stats_dialog(text)
    local t = text:gsub("%s", ""); local bal = get_bal()
    local sc = t:match('%(SA%$%)::CASH:(%d[%d%.]*)'); if sc then bal.sa.cash = extract_money(sc) end
    local vc = t:match('%(VC%$%)::CASHV:(%d[%d%.]*)'); if vc then bal.vc.cash = extract_money(vc) end
    local sb = t:match('Деньгивбанке::CASH:(%d[%d%.]*)'); if sb then bal.sa.bank = extract_money(sb) end
    local pt = 0; for i = 1, 6 do local p = t:match('Состояниеличногосчета№' .. i .. '::CASH:(%d[%d%.]*)'); if p then pt = pt + extract_money(p) end end
    bal.sa.personal = pt
    local sd = t:match('Деньгинадепозите::CASH:(%d[%d%.]*)'); if sd then bal.sa.deposit = extract_money(sd) end
    local vb = t:match('Деньгивбанке::CASHV:(%d[%d%.]*)'); if vb then bal.vc.bank = extract_money(vb) end
    local vd = t:match('Деньгинадепозите::CASHV:(%d[%d%.]*)'); if vd then bal.vc.deposit = extract_money(vd) end
    local az = t:match('([%d%.]+)AZ%-Coins'); if az then bal.az = extract_money(az) end
    local bt = t:match('BTC:{FF6347}%[(%d+)%]'); if bt then bal.btc = tonumber(bt) or bal.btc end
    local eu = t:match('Евро:{FF6347}%[(%d+)%]'); if eu then bal.euro = tonumber(eu) or bal.euro end
    local today = get_today(); local sk = current_server or "__pending__"
    if not day_start[sk] then day_start[sk] = {} end
    if not day_start[sk][today] or is_all_zero(day_start[sk][today]) then
        day_start[sk][today] = { sa = { cash = bal.sa.cash, bank = bal.sa.bank, personal = bal.sa.personal, deposit = bal.sa.deposit }, vc = { cash = bal.vc.cash, bank = bal.vc.bank, deposit = bal.vc.deposit }, az = bal.az, btc = bal.btc, euro = bal.euro, asc = bal.asc, eth = bal.eth, ltc = bal.ltc }
        save_data()
    end
    save_balance_to_history()
end

local function request_stats(cb) stats_pending = true; stats_callback = cb; sampSendChat('/stats') end

local function auto_snapshot()
    request_stats(function() sampAddChatMessage('[BalanceTracker] Денюшки подсчитаны :CASH: :CASHV:, глянь! /bt', 0xFFD700) end)
end

local function show_help()
    sampShowDialog(1, "Balance Tracker - Помощь",
        "{FFD700}=== BALANCE TRACKER v3.2 ===\n\n" ..
        "{FFD700} :CASH: БАЛАНС\n{FFFFFF}/bt\t\t— баланс на сегодня\n\n" ..
        "{FFD700} :CHART: ИСТОРИЯ\n{FFFFFF}/bh\t\t— история по дням\n{FFFFFF}/bn /bp\t— листание недель\n{FFFFFF}/bweek\t— список недель\n\n" ..
        "{FFD700} :ARZ: СЕРВЕРА\n{FFFFFF}/bserv\t— балансы по серверам\n\n" ..
        "{FFD700} :u1f4b8: БАНК. ПЕРЕВОДЫ\n{FFFFFF}/bpere\t— история переводов\n{FFFFFF}/bpn /bpp\t— листание недель\n\n" ..
        "{FFD700} :u1f4b5: НАЛИЧНЫЕ /PAY\n{FFFFFF}/bpay\t— история передач\n{FFFFFF}/bpayn /bpayp — листание\n\n" ..
        "{FFD700} :ATM: ОБМЕННИКИ\n{FFFFFF}Автоматически: VC$, BTC, ASC, Евро\n\n" ..
        "{FFD700} :u1f5d1: СБРОС\n{FFFFFF}/breset /bresetall\n\n{888888}Balance Tracker v3.2 by Victor_Pobedov :ARZ: Winslow",
    "OK", "", 0)
end

local function show_weeks()
    local lines = {"{FFD700}=== ДОСТУПНЫЕ НЕДЕЛИ ===\n\n"}
    local hw, tw, pw, cw = get_available_weeks("history"), get_available_weeks("transfers"), get_available_weeks("pays"), get_current_week()
    
    local function add_section(title, weeks)
        table.insert(lines, string.format("{FFD700}%s:\n", title))
        if #weeks == 0 then table.insert(lines, "{FFFFFF}  Нет данных\n") else
            for _, w in ipairs(weeks) do table.insert(lines, string.format("  {FFFFFF}%04d %s, нед. %d%s\n", w.year, os.date("%B", os.time({year=w.year, month=w.month, day=1})), w.week, w.key == cw and " <" or "")) end
        end
        table.insert(lines, "\n")
    end
    
    add_section("История", hw)
    add_section("Банковские переводы", tw)
    add_section("Наличные передачи", pw)
    table.insert(lines, "{888888}/bthelp")
    sampShowDialog(1, "Balance Tracker - Недели", table.concat(lines), "OK", "", 0)
end

local function show_stats()
    local bal = get_bal()
    if is_all_zero(bal) then sampShowDialog(1, "Balance Tracker", "{FFD700}Пока что у вас нет денюшек.\n\n{FFFFFF}Загляните позже!\n\n{888888}/bthelp", "OK", "", 0); return end
    
    local is_vc_, today, sk = is_vc(), get_today(), current_server or "__pending__"
    local ds = (day_start[sk] and day_start[sk][today]) or {}
    local dss, dsv = ds.sa or { cash = 0, bank = 0, personal = 0, deposit = 0 }, ds.vc or { cash = 0, bank = 0, deposit = 0 }
    local lines = { string.format("{FFD700}=== БАЛАНС НА %s ===  %s %s\n\n", today, get_server_icon(), current_server and string.format("{FFD700}[%s]", get_server_name()) or "{888888}[?]") }
    
    local sa_lines, sa_total = {}, 0
    if bal.sa.cash > 0 then table.insert(sa_lines, string.format("{FFFFFF}Наличные (SA$):\t{33AA33}%s%s\t%s\n", CSA, format_money(bal.sa.cash), format_diff(bal.sa.cash - dss.cash, CSA))); sa_total = sa_total + bal.sa.cash end
    if not is_vc_ and bal.sa.bank > 0 then table.insert(sa_lines, string.format("{FFFFFF}Банк (SA$):\t\t{33AA33}%s%s\t%s\n", CSA, format_money(bal.sa.bank), format_diff(bal.sa.bank - (dss.bank or 0), CSA))); sa_total = sa_total + bal.sa.bank end
    if not is_vc_ and bal.sa.personal > 0 then table.insert(sa_lines, string.format("{FFFFFF}Личные счета:\t{33AA33}%s%s\t%s\n", CSA, format_money(bal.sa.personal), format_diff(bal.sa.personal - (dss.personal or 0), CSA))); sa_total = sa_total + bal.sa.personal end
    if not is_vc_ and bal.sa.deposit > 0 then table.insert(sa_lines, string.format("{FFFFFF}Депозит (SA$):\t{33AA33}%s%s\t%s\n", CSA, format_money(bal.sa.deposit), format_diff(bal.sa.deposit - (dss.deposit or 0), CSA))); sa_total = sa_total + bal.sa.deposit end
    if is_vc_ then
        if bal.sa.bank > 0 then table.insert(sa_lines, string.format("{888888}Банк (SA$):\t\t{888888}%s%s\t(недоступен)\n", CSA, format_money(bal.sa.bank))); sa_total = sa_total + bal.sa.bank end
        if bal.sa.personal > 0 then table.insert(sa_lines, string.format("{888888}Личные счета:\t{888888}%s%s\t(недоступен)\n", CSA, format_money(bal.sa.personal))); sa_total = sa_total + bal.sa.personal end
        if bal.sa.deposit > 0 then table.insert(sa_lines, string.format("{888888}Депозит (SA$):\t{888888}%s%s\t(недоступен)\n", CSA, format_money(bal.sa.deposit))); sa_total = sa_total + bal.sa.deposit end
    end
    if #sa_lines > 1 then for _, l in ipairs(sa_lines) do table.insert(lines, l) end; table.insert(lines, string.format("{FFD700}-----------------------\n{FFD700}Всего (SA$):\t\t%s%s%s\t%s\n", is_vc_ and "{888888}" or "{33AA33}", CSA, format_money(sa_total), format_diff(sa_total - ((dss.cash or 0)+(dss.bank or 0)+(dss.personal or 0)+(dss.deposit or 0)), CSA)))
    elseif #sa_lines == 1 then table.insert(lines, sa_lines[1]) end
    
    local vc_lines, vc_total = {}, 0
    if bal.vc.cash > 0 then table.insert(vc_lines, string.format("{FFFFFF}Наличные (VC$):\t{FF69B4}%s%s\t%s\n", CVC, format_money(bal.vc.cash), format_diff(bal.vc.cash - dsv.cash, CVC))); vc_total = vc_total + bal.vc.cash end
    if is_vc_ and bal.vc.bank > 0 then table.insert(vc_lines, string.format("{FFFFFF}Банк (VC$):\t\t{FF69B4}%s%s\t%s\n", CVC, format_money(bal.vc.bank), format_diff(bal.vc.bank - (dsv.bank or 0), CVC))); vc_total = vc_total + bal.vc.bank end
    if is_vc_ and bal.vc.deposit > 0 then table.insert(vc_lines, string.format("{FFFFFF}Депозит (VC$):\t{FF69B4}%s%s\t%s\n", CVC, format_money(bal.vc.deposit), format_diff(bal.vc.deposit - (dsv.deposit or 0), CVC))); vc_total = vc_total + bal.vc.deposit end
    if not is_vc_ then
        if bal.vc.bank > 0 then table.insert(vc_lines, string.format("{888888}Банк (VC$):\t\t{888888}%s%s\t(недоступен)\n", CVC, format_money(bal.vc.bank))); vc_total = vc_total + bal.vc.bank end
        if bal.vc.deposit > 0 then table.insert(vc_lines, string.format("{888888}Депозит (VC$):\t{888888}%s%s\t(недоступен)\n", CVC, format_money(bal.vc.deposit))); vc_total = vc_total + bal.vc.deposit end
    end
    if #vc_lines > 1 then if #sa_lines > 0 then table.insert(lines, "\n") end; for _, l in ipairs(vc_lines) do table.insert(lines, l) end; table.insert(lines, string.format("{FFD700}-----------------------\n{FFD700}Всего (VC$):\t\t%s%s%s\t%s\n", (not is_vc_) and "{888888}" or "{FF69B4}", CVC, format_money(vc_total), format_diff(vc_total - ((dsv.cash or 0)+(dsv.bank or 0)+(dsv.deposit or 0)), CVC)))
    elseif #vc_lines == 1 then if #sa_lines > 0 then table.insert(lines, "\n") end; table.insert(lines, vc_lines[1]) end
    
    local rates = exchange_rates[today]
    local has_crypto = (bal.az > 0) or (bal.btc > 0) or (bal.eth > 0) or (bal.ltc > 0) or (bal.asc > 0) or (bal.euro > 0)
    if has_crypto then table.insert(lines, "\n") end
    
    if bal.az > 0 then
        local diff_az = bal.az - (ds.az or 0)
        table.insert(lines, string.format("{FFFFFF}AZ-Coins:\t\t{00BFFF}%d AZ\t%s\n", bal.az, diff_az ~= 0 and format_diff_int(diff_az) or ""))
    end
    
    local function ac(label, color, amount, rate, ds_amount)
        if (amount or 0) > 0 then
            local s = string.format("{FFFFFF}%s:\t\t\t%s%d %s", label, color, amount, label)
            if ds_amount then
                local diff = amount - ds_amount
                if diff > 0 then s = s .. string.format("  {33AA33}+%d", diff)
                elseif diff < 0 then s = s .. string.format("  {FF6347}%d", diff) end
            end
            if rate then
                s = s .. string.format("\t%s(%s%s)", rate_color(rates and rates.date), CSA, format_money(amount * rate))
            end
            table.insert(lines, s .. "\n")
        end
    end
    
    ac("BTC", "{FFA500}", bal.btc, rates and rates.btc_rate, ds.btc)
    ac("ETH", "{888888}", bal.eth, rates and rates.eth_rate, ds.eth)
    ac("LTC", "{AAAAAA}", bal.ltc, rates and rates.ltc_rate, ds.ltc)
    ac("ASC", "{FF6347}", bal.asc, rates and rates.asc_rate, ds.asc)
    ac("Евро", "{FFD700}", bal.euro, rates and rates.euro_rate, ds.euro)
    
    table.insert(lines, string.format("\n\n{888888}/bthelp помощь | /bserv серверы | /bh история | /bpere переводы | /bpay передачи"))
    sampShowDialog(1, "Balance Tracker", table.concat(lines), "OK", "", 0)
end

local function show_history(wk)
    local sk = current_server or "__pending__"
    wk = wk or get_current_week(); current_history_week = wk
    local hist = load_week_file("history", wk)
    local sh = hist[sk] or {}
    local dates = {}; for d, _ in pairs(sh) do table.insert(dates, d) end; table.sort(dates, function(a, b) return a > b end)
    local pp = 8; local tp = math.ceil(#dates / pp); if tp == 0 then tp = 1 end
    if not data.history_page then data.history_page = 1 end
    local page = data.history_page; if page > tp then page = tp end; if page < 1 then page = 1 end; data.history_page = page
    local si = (page - 1) * pp + 1; local ei = math.min(si + pp - 1, #dates)
    
    local lines = {}
    table.insert(lines, "{FFD700}=== ИСТОРИЯ БАЛАНСА ===\n")
    table.insert(lines, string.format("{FFFFFF}/bn далее | /bp назад | /bh начало | /bthelp помощь\n\n"))
    
    if #dates == 0 then
        table.insert(lines, "{FFFFFF}Нет данных за эту неделю.\n")
    else
        for i = si, ei do
            local date = dates[i]; local bal = sh[date]
            if bal and not is_all_zero(bal) then
                local sa = { cash = bal.sa[1] or 0, bank = bal.sa[2] or 0, personal = bal.sa[3] or 0, deposit = bal.sa[4] or 0 }
                local vc = { cash = bal.vc[1] or 0, bank = bal.vc[2] or 0, deposit = bal.vc[3] or 0 }
                local pd = (i < #dates) and dates[i + 1] or nil; local pb = pd and sh[pd]
                local psa = pb and { cash = pb.sa[1] or 0, bank = pb.sa[2] or 0, personal = pb.sa[3] or 0, deposit = pb.sa[4] or 0 } or { cash = 0, bank = 0, personal = 0, deposit = 0 }
                local pvc = pb and { cash = pb.vc[1] or 0, bank = pb.vc[2] or 0, deposit = pb.vc[3] or 0 } or { cash = 0, bank = 0, deposit = 0 }
                local function df(v, pv, C) return pb and format_diff(v - pv, C) or "" end
                local function di(v, pv) return pb and format_diff_int(v - pv) or "" end
                
                local sa_count, vc_count, sa_total, vc_total = 0, 0, 0, 0
                local day_lines = {}
                
                if sa.cash > 0 then table.insert(day_lines, string.format("  {FFFFFF}SA$ нал:\t{33AA33}%s%s %s\n", CSA, format_money(sa.cash), df(sa.cash, psa.cash, CSA))); sa_count = sa_count + 1; sa_total = sa_total + sa.cash end
                if sa.bank > 0 then table.insert(day_lines, string.format("  {FFFFFF}SA$ банк:\t{33AA33}%s%s %s\n", CSA, format_money(sa.bank), df(sa.bank, psa.bank, CSA))); sa_count = sa_count + 1; sa_total = sa_total + sa.bank end
                if sa.personal > 0 then table.insert(day_lines, string.format("  {FFFFFF}SA$ личн:\t{33AA33}%s%s %s\n", CSA, format_money(sa.personal), df(sa.personal, psa.personal, CSA))); sa_count = sa_count + 1; sa_total = sa_total + sa.personal end
                if sa.deposit > 0 then table.insert(day_lines, string.format("  {FFFFFF}SA$ деп:\t{33AA33}%s%s %s\n", CSA, format_money(sa.deposit), df(sa.deposit, psa.deposit, CSA))); sa_count = sa_count + 1; sa_total = sa_total + sa.deposit end
                
                if vc.cash > 0 then table.insert(day_lines, string.format("  {FFFFFF}VC$ нал:\t{FF69B4}%s%s %s\n", CVC, format_money(vc.cash), df(vc.cash, pvc.cash, CVC))); vc_count = vc_count + 1; vc_total = vc_total + vc.cash end
                if vc.bank > 0 then table.insert(day_lines, string.format("  {FFFFFF}VC$ банк:\t{FF69B4}%s%s %s\n", CVC, format_money(vc.bank), df(vc.bank, pvc.bank, CVC))); vc_count = vc_count + 1; vc_total = vc_total + vc.bank end
                if vc.deposit > 0 then table.insert(day_lines, string.format("  {FFFFFF}VC$ деп:\t{FF69B4}%s%s %s\n", CVC, format_money(vc.deposit), df(vc.deposit, pvc.deposit, CVC))); vc_count = vc_count + 1; vc_total = vc_total + vc.deposit end
                
                if (bal.az or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}AZ:\t\t{00BFFF}%d %s\n", bal.az, di(bal.az, pb and pb.az or 0))) end
                if (bal.bt or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}BTC:\t\t{FFA500}%d %s\n", bal.bt, di(bal.bt, pb and pb.bt or 0))) end
                if (bal.eu or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}Евро:\t\t{FFD700}%d %s\n", bal.eu, di(bal.eu, pb and pb.eu or 0))) end
                if (bal.as or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}ASC:\t\t{FF6347}%d %s\n", bal.as, di(bal.as, pb and pb.as or 0))) end
                if (bal.et or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}ETH:\t\t{888888}%d %s\n", bal.et, di(bal.et, pb and pb.et or 0))) end
                if (bal.lt or 0) > 0 then table.insert(day_lines, string.format("  {FFFFFF}LTC:\t\t{AAAAAA}%d %s\n", bal.lt, di(bal.lt, pb and pb.lt or 0))) end
                
                if sa_count + vc_count > 0 then
                    table.insert(lines, string.format("{FFD700}%s\n", date))
                    for _, l in ipairs(day_lines) do table.insert(lines, l) end
                    if sa_count > 1 then
                        local psa_total = (psa.cash or 0) + (psa.bank or 0) + (psa.personal or 0) + (psa.deposit or 0)
                        table.insert(lines, string.format("  {FFD700}--- {FFFFFF}Всего SA$:\t{33AA33}%s%s %s\n", CSA, format_money(sa_total), df(sa_total, psa_total, CSA)))
                    end
                    if vc_count > 1 then
                        local pvc_total = (pvc.cash or 0) + (pvc.bank or 0) + (pvc.deposit or 0)
                        table.insert(lines, string.format("  {FFD700}--- {FFFFFF}Всего VC$:\t{FF69B4}%s%s %s\n", CVC, format_money(vc_total), df(vc_total, pvc_total, CVC)))
                    end
                    table.insert(lines, "\n")
                end
            end
        end
    end
    
    if #dates > pp then
        table.insert(lines, string.format("{888888}Страница %d/%d | /bn /bp\n", page, tp))
    end
    
    local text = table.concat(lines)
    sampShowDialog(1, "Balance Tracker - История", text, "OK", "", 0)
end

local function show_servers()
    local lines = {"{FFD700}=== БАЛАНСЫ ПО СЕРВЕРАМ ===\n\n"}
    local sn = {}; for n, _ in pairs(balances) do if n ~= "__pending__" then table.insert(sn, n) end end; table.sort(sn)
    if balances["__pending__"] then table.insert(sn, 1, "?") end
    if #sn == 0 then table.insert(lines, "{FFFFFF}Нет данных.\n")
    else
        for _, n in ipairs(sn) do
            local b, ic = balances[n == "?" and "__pending__" or n], (n == "?" and not current_server) or (n == current_server)
            local ts = (b.sa.cash or 0) + (b.sa.bank or 0) + (b.sa.personal or 0) + (b.sa.deposit or 0)
            table.insert(lines, string.format("%s%s %s: %s%s%s\n", ic and "{FFFFFF}" or "{888888}", n:find("VC") and ":VC:" or ":ARZ:", n, CSA, format_money(ts), ic and "" or " (недоступен)"))
        end
    end
    table.insert(lines, "\n{888888}/bthelp")
    sampShowDialog(1, "Balance Tracker - Серверы", table.concat(lines), "OK", "", 0)
end

-- Универсальная функция показа списка (переводы или передачи)
-- Универсальная функция показа списка (переводы или передачи)
local function show_transaction_list(prefix, title, count_key, current_week_var, wk)
    wk = wk or get_current_week()
    if prefix == "transfers" then current_transfers_week = wk else current_pays_week = wk end
    
    local items = load_week_file(prefix, wk)
    local arrow_in = prefix == "transfers" and "{33AA33}< банк" or "{33AA33}< нал"
    local arrow_out = prefix == "transfers" and "{FF6347}> банк" or "{FF6347}> нал"
    
    if #items == 0 then
        sampShowDialog(1, "Balance Tracker - " .. title, string.format("{FFFFFF}Нет данных за неделю %s.\n\n{888888}/bthelp", wk), "OK", "", 0)
    else
        local lines = { string.format("{FFD700}=== %s (нед. %s) ===\n\n", title, wk) }
        local c = 0
        -- Показываем последние 30, начиная с новых
        local total = #items
        local start_idx = math.max(1, total - 29)
        for i = total, start_idx, -1 do
            local tr = items[i]
            local arrow = tr.type == "out" and arrow_out or arrow_in
            -- Новые (непрочитанные) помечаем стрелкой <---
            local new_marker = ""
            if i > total - 5 then -- последние 5 считаем новыми если есть unread
                local is_unread = (prefix == "transfers" and data.unread_transfers) or (prefix == "pays" and data.unread_pays)
                if is_unread then
                    new_marker = " {FFD700}<---"
                end
            end
            table.insert(lines, string.format("{FFFFFF}%s | %s {00CED1}%s{FFFFFF}: %s%s%s%s\n", 
                tr.date, arrow, tr.from, 
                tr.type == "out" and "{FF6347}" or "{33AA33}", 
                CSA, format_money(tr.amount),
                new_marker))
            c = c + 1
        end
        table.insert(lines, string.format("\n{FFFFFF}За неделю: %d | Всего: %d", #items, data[count_key] or 0))
        local nav = prefix == "transfers" and "/bpn /bpp" or "/bpayn /bpayp"
        table.insert(lines, string.format("\n{888888}%s /bthelp", nav))
        sampShowDialog(1, "Balance Tracker - " .. title, table.concat(lines), "OK", "", 0)
    end
    
    if prefix == "transfers" then data.unread_transfers = false else data.unread_pays = false end
end

local function handle_exchange(text, mode, curr)
    local t = text:gsub("%s", ""); local cn, cv = {}, {}
    for n in t:gmatch(':CASH:(%d[%d%.]*)') do table.insert(cn, n) end
    for n in t:gmatch(':CASHV:(%d[%d%.]*)') do table.insert(cv, n) end
    local bal = get_bal()
    
    local function safe_tonumber(s)
        if not s then return nil end
        if type(s) ~= "string" then return nil end
        local clean = s:gsub('%.', '')
        if clean == "" then return nil end
        return tonumber(clean)
    end
    
    if mode == "vc_buy" and #cn >= 2 and #cv >= 1 then
        local rs, sb_, rv = safe_tonumber(cn[1]), safe_tonumber(cn[2]), safe_tonumber(cv[1])
        if rs and sb_ and rv and rv > 0 then
            sampAddChatMessage(string.format('[:VC: Exchange] Купить максимум: %s%s (%s%s, курс: %d/%d)', CVC, format_money(math.floor(sb_ * rv / rs)), CSA, format_money(sb_), rs, rv), 0xFFD700)
        end
    elseif mode == "vc_sell" and #cn >= 1 and #cv >= 2 then
        local rs, vb_, rv = safe_tonumber(cn[1]), safe_tonumber(cv[2]), safe_tonumber(cv[1])
        if rs and vb_ and rv and rv > 0 then
            sampAddChatMessage(string.format('[:VC: Exchange] Продать максимум: %s%s (%s%s, курс: %d/%d)', CSA, format_money(math.floor(vb_ * rs / rv)), CVC, format_money(vb_), rs, rv), 0xFFD700)
        end
    elseif mode == "crypto_buy" and #cn >= 1 then
        local r = safe_tonumber(cn[1])
        if r and bal.sa.cash > 0 then
            local av_match = t:match('Вбанкедоступно:(%d+)') or t:match('доступно:(%d+)')
            local av = 999999999
            if av_match then av = safe_tonumber(av_match) or 999999999 end
            local mb = math.min(av, math.floor(bal.sa.cash / r))
            if mb > 0 then
                sampAddChatMessage(string.format('[%s Exchange] Купить максимум: %d %s за %s%s (курс: %s%s/%s)', curr, mb, curr, CSA, format_money(mb * r), CSA, format_money(r), curr), 0xFFD700)
            end
        elseif r then
            sampAddChatMessage(string.format('[%s Exchange] Курс: %s%s/%s (нет SA$)', curr, CSA, format_money(r), curr), 0xFFD700)
        end
    elseif mode == "crypto_sell" and #cn >= 1 then
        local r = safe_tonumber(cn[1])
        local have = curr == "BTC" and bal.btc or curr == "EURO" and bal.euro or curr == "ASC" and bal.asc or curr == "ETH" and bal.eth or curr == "LTC" and bal.ltc or 0
        local hm = t:match('Увасесть:(%d+)') or t:match('УВасесть:(%d+)') or t:match('есть:(%d+)')
        if hm then have = safe_tonumber(hm) or have end
        if r and have and have > 0 then
            sampAddChatMessage(string.format('[%s Exchange] Продать максимум: %s%s за %d %s (курс: %s%s/%s)', curr, CSA, format_money(have * r), have, curr, CSA, format_money(r), curr), 0xFFD700)
        elseif r then
            sampAddChatMessage(string.format('[%s Exchange] Курс: %s%s/%s (нет %s)', curr, CSA, format_money(r), curr, curr), 0xFFD700)
        end
    end
end

-- Добавление транзакции (перевод или передача)
local function add_transaction(prefix, amount, from, tr_type, currency)
    local tr = { date = get_today() .. " " .. os.date("%H:%M:%S"), from = from, amount = amount, type = tr_type }
    local wk = get_current_week()
    local items = load_week_file(prefix, wk)
    table.insert(items, tr)
    save_week_file(prefix, wk, items)
    if prefix == "transfers" then transfers_cache[wk] = items else pays_cache[wk] = items end
    local count_key = prefix == "transfers" and "transfers_count" or "pays_count"
    data[count_key] = (data[count_key] or 0) + 1
    if prefix == "transfers" then data.unread_transfers = true else data.unread_pays = true end
    save_data()
    
    local arrow = tr_type == "out" and ">" or "<"
    local sign = tr_type == "out" and "-" or "+"
    local color = tr_type == "out" and 0xFF6347 or 0x00CED1
    local label = prefix == "transfers" and "банк" or "нал"
    sampAddChatMessage(string.format('  [BalanceTracker] %s%s%s %s %s (%s)', sign, currency or CSA, format_money(amount), arrow, from, label), color)
end

function sampev.onShowDialog(did, style, title, b1, b2, text)
    if did == 0 and text:find('Bitcoin') then parse_rates_dialog(text) end
    if stats_pending and (text:find('Деньги в банке') or text:find('Деньгивбанке')) then parse_stats_dialog(text); stats_pending = false; sampCloseCurrentDialogWithButton(0); if stats_callback then stats_callback(); stats_callback = nil end; return false end
    if text:find('Сервер, на котором Вы находитесь') then detect_server_from_exchange(text) end
    if title:find('Покупка VC') then handle_exchange(text, "vc_buy", "VC") end
    if title:find('Продажа VC') then handle_exchange(text, "vc_sell", "VC") end
    if title:find('Купить BTC') then handle_exchange(text, "crypto_buy", "BTC") end
    if title:find('Продать BTC') then handle_exchange(text, "crypto_sell", "BTC") end
    if title:find('Купить ASC') then handle_exchange(text, "crypto_buy", "ASC") end
    if title:find('Продать ASC') then handle_exchange(text, "crypto_sell", "ASC") end
    if text:find('приобрести ЕВРО') then handle_exchange(text, "crypto_buy", "EURO") end
    if text:find('продать ЕВРО') then handle_exchange(text, "crypto_sell", "EURO") end
    if title:find('Пункт обмена') then
        local t = text:gsub("%s", ""); local bs, bv = t:match('КупитьVC[^{]*%[:CASH:(%d+)/:CASHV:(%d+)%]'); local ss, sv = t:match('ПродатьVC[^{]*%[:CASH:(%d+)/:CASHV:(%d+)%]')
        if bs and ss then sampAddChatMessage(string.format('[:VC: Exchange] Курсы: покупка %s%s/%s1 | продажа %s%s/%s1', CSA, bs, CVC, CSA, ss, CVC), 0xFFD700) end
    end
end

function sampev.onServerMessage(color, msg)
    local t = msg:gsub("%s", "")
    if t:find('Общаязаработнаяплата:') then payday_detected = true; payday_timer = os.clock() end
    
    -- Банковский перевод входящий: Вам поступил перевод на ваш счет в размере :CASH:100 от жителя ИМЯ(ID)
    if msg:find('поступил перевод') then
        local cur = msg:find('CASHV') and CVC or CSA
        local am_str = msg:match(':CASH:(%d[%d%.]*)')
        if not am_str then am_str = msg:match(':CASHV:(%d[%d%.]*)'); if am_str then cur = CVC end end
        local fm = msg:match('от жителя (.+)%(%d+%)')
        if am_str and fm then
            local a = extract_money(am_str)
            if a > 0 then add_transaction("transfers", a, fm, "in", cur) end
        end
    end
    
    -- Банковский перевод исходящий: Вы перевели :CASH:1 игроку ИМЯ(ID) на счет
    if msg:find('Вы перевели') and msg:find('игроку') then
        local cur = msg:find('CASHV') and CVC or CSA
        local am_str = msg:match('перевели :CASH:(%d[%d%.]*)')
        if not am_str then am_str = msg:match('перевели :CASHV:(%d[%d%.]*)'); if am_str then cur = CVC end end
        local tm = msg:match('игроку (.+)%(%d+%)')
        if am_str and tm then
            local a = extract_money(am_str)
            if a > 0 then add_transaction("transfers", a, tm, "out", cur) end
        end
    end
    
    -- /pay исходящий: Вы передали :CASH:12 12cilindri
    if msg:find('Вы передали') and not msg:find('игроку') then
        local cur = msg:find('CASHV') and CVC or CSA
        local am_str, to = msg:match('Вы передали :CASH:(%d[%d%.]*)%s+(.+)')
        if not am_str then
            am_str, to = msg:match('Вы передали :CASHV:(%d[%d%.]*)%s+(.+)')
            if am_str then cur = CVC end
        end
        if am_str and to then
            local a = extract_money(am_str)
            if a > 0 then add_transaction("pays", a, to, "out", cur) end
        end
    end
    
    -- /pay входящий: 12cilindri передал(а) вам :CASH:12
    if msg:find('передал') and not msg:find('игроку') then
        local cur = msg:find('CASHV') and CVC or CSA
        local from, am_str = msg:match('(.+) передал%(а%) вам :CASH:(%d[%d%.]*)')
        if not from then
            from, am_str = msg:match('(.+) передал%(а%) вам :CASHV:(%d[%d%.]*)')
            if from then cur = CVC end
        end
        if from and am_str then
            local a = extract_money(am_str)
            if a > 0 then add_transaction("pays", a, from, "in", cur) end
        end
    end
end

function sampev.onSendCommand(cmd)
    if cmd == '/bt' then request_stats(show_stats); return false end
    if cmd == '/bh' then data.history_page = 1; show_history(get_current_week()); return false end
    if cmd == '/bn' then local nw = get_adjacent_week(current_history_week or get_current_week(), "next"); if nw then data.history_page = 1; show_history(nw) end; return false end
    if cmd == '/bp' then local pw = get_adjacent_week(current_history_week or get_current_week(), "prev"); if pw then data.history_page = 1; show_history(pw) end; return false end
    if cmd == '/bpere' then show_transaction_list("transfers", "БАНКОВСКИЕ ПЕРЕВОДЫ", "transfers_count", current_transfers_week, get_current_week()); return false end
    if cmd == '/bpn' then local nw = get_adjacent_week(current_transfers_week or get_current_week(), "next"); if nw then show_transaction_list("transfers", "БАНКОВСКИЕ ПЕРЕВОДЫ", "transfers_count", current_transfers_week, nw) end; return false end
    if cmd == '/bpp' then local pw = get_adjacent_week(current_transfers_week or get_current_week(), "prev"); if pw then show_transaction_list("transfers", "БАНКОВСКИЕ ПЕРЕВОДЫ", "transfers_count", current_transfers_week, pw) end; return false end
    if cmd == '/bpay' then show_transaction_list("pays", "НАЛИЧНЫЕ ПЕРЕДАЧИ", "pays_count", current_pays_week, get_current_week()); return false end
    if cmd == '/bpayn' then local nw = get_adjacent_week(current_pays_week or get_current_week(), "next"); if nw then show_transaction_list("pays", "НАЛИЧНЫЕ ПЕРЕДАЧИ", "pays_count", current_pays_week, nw) end; return false end
    if cmd == '/bpayp' then local pw = get_adjacent_week(current_pays_week or get_current_week(), "prev"); if pw then show_transaction_list("pays", "НАЛИЧНЫЕ ПЕРЕДАЧИ", "pays_count", current_pays_week, pw) end; return false end
    if cmd == '/bweek' then show_weeks(); return false end
    if cmd == '/bserv' then show_servers(); return false end
    if cmd == '/bthelp' then show_help(); return false end
    if cmd == '/breset' then local bal = get_bal(); for k, _ in pairs(bal.sa) do bal.sa[k] = 0 end; for k, _ in pairs(bal.vc) do bal.vc[k] = 0 end; bal.az, bal.btc, bal.euro, bal.asc, bal.eth, bal.ltc = 0,0,0,0,0,0; data.unread_transfers, data.unread_pays = false, false; save_data(); sampAddChatMessage('[BalanceTracker] Данные сброшены.', 0xFF6347); return false end
    if cmd == '/bresetall' then
        for _, w in ipairs(get_available_weeks("history")) do os.remove(BASE_DIR .. "history_" .. w.key .. ".json") end
        for _, w in ipairs(get_available_weeks("transfers")) do os.remove(BASE_DIR .. "transfers_" .. w.key .. ".json") end
        for _, w in ipairs(get_available_weeks("pays")) do os.remove(BASE_DIR .. "pays_" .. w.key .. ".json") end
        data.balances, data.current_server, data.server_ips, data.exchange_rates, data.day_start = {}, nil, {}, {}, {}
        data.transfers_count, data.pays_count, data.unread_transfers, data.unread_pays = 0, 0, false, false
        balances, current_server, server_ips, exchange_rates, day_start = data.balances, nil, data.server_ips, data.exchange_rates, data.day_start
        history_cache, transfers_cache, pays_cache = {}, {}, {}
        save_data(); sampAddChatMessage('[BalanceTracker] Всё очищено.', 0xFF6347); return false
    end
end

function main()
    if not isSampLoaded() then return end; while not isSampAvailable() do wait(100) end
    if not data.history_page then data.history_page = 1 end
    if not data.balances then data.balances = {}; balances = data.balances end
    if not data.server_ips then data.server_ips = {}; server_ips = data.server_ips end
    if not data.exchange_rates then data.exchange_rates = {}; exchange_rates = data.exchange_rates end
    if not data.day_start then data.day_start = {}; day_start = data.day_start end
    if not data.unread_transfers then data.unread_transfers = false end
    if not data.unread_pays then data.unread_pays = false end
    if not data.transfers_count then data.transfers_count = 0 end
    if not data.pays_count then data.pays_count = 0 end
    
    local ip = sampGetCurrentServerAddress() or ""
    if ip ~= "" and server_ips[ip] and not current_server then
        current_server = server_ips[ip]; data.current_server = current_server
        if balances["__pending__"] then balances[current_server] = balances["__pending__"]; balances["__pending__"] = nil end
        if day_start["__pending__"] then day_start[current_server] = day_start["__pending__"]; day_start["__pending__"] = nil end
        save_data(); sampAddChatMessage(string.format('[BalanceTracker] Сервер: %s %s', get_server_icon(), current_server), 0xFFD700)
    end
    
    os.execute('mkdir "' .. BASE_DIR .. '" 2>nul')
    sampAddChatMessage(string.format('[BalanceTracker %s] v3.2 загружен. /bthelp', get_server_icon()), 0xFFD700)
    if saved then sampAddChatMessage('[BalanceTracker] Данные загружены.', 0xFFD700) end
    if not current_server then sampAddChatMessage('[BalanceTracker] Сервер не определён. Откройте обменник.', 0xFFD700) end
    
    lua_thread.create(function() while true do wait(1000); if payday_detected and os.clock() - payday_timer >= 20 then payday_detected = false; if isSampAvailable() then auto_snapshot() end end end end)
	lua_thread.create(function()
		while true do
			wait(30000)
			if isSampAvailable() then
				if data.unread_transfers then
					sampAddChatMessage('[BalanceTracker] < Новые банковские переводы! /bpere', 0x00CED1)
				end
				if data.unread_pays then
					sampAddChatMessage('[BalanceTracker] < Новые наличные передачи! /bpay', 0xFFD700)
				end
			end
		end
	end)
end