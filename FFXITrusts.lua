_addon.name     = 'FFXITrusts'
_addon.author   = 'Jason'
_addon.version  = '1.1'
_addon.commands = {'ft', 'ftrusts'}

local config = require('config')
local images = require('images')
local texts  = require('texts')
local res    = require('resources')

-- Pre-build set of every trust spell ID so the action-event listener can
-- confirm a finished cast really was a trust (not, say, your /WHM Cure).
-- Also build a name → id-list lookup so we can answer "do I know this
-- trust?" before issuing the /ma command (saves us from a 30s timeout +
-- retries on UC trusts the player never unlocked).
--
-- Why id-LIST instead of single id: multiple trusts can share the same
-- shorthand name. Examples from res/spells.lua:
--   * Shantotto (id 896) and Shantotto II (id 1019) — id 1019's party_name
--     is just "Shantotto" so a user with only Shantotto II in their book
--     gets falsely flagged "not learned" if we only stored id 896.
--   * "Semih Lafihna" en field has a space but party_name is "SemihLafihna"
--     — saved sets that copy-pasted the party-name form fail the en lookup.
-- We index every Trust under BOTH `en` and `party_name` (each lowercased
-- too for case-insensitive saved-set names), and store a LIST of candidate
-- ids per key. trust_is_owned() returns true if ANY candidate is learned.
local trust_spell_ids = {}
local trust_id_by_name = {}
local function add_alias(key, id)
    if not key or key == '' then return end
    if not trust_id_by_name[key] then trust_id_by_name[key] = {} end
    table.insert(trust_id_by_name[key], id)
end
for id, spell in pairs(res.spells) do
    if spell.type == 'Trust' then
        trust_spell_ids[id] = true
        add_alias(spell.en, id)
        add_alias((spell.en or ''):lower(), id)
        add_alias(spell.party_name, id)
        add_alias((spell.party_name or ''):lower(), id)
    end
end

-- True if the character has the named trust learned (i.e. it's in their
-- spell book). Returns false for any name we can't even find in resources.
-- Walks the candidate-id list (see comment by trust_id_by_name build) so
-- ambiguous shorthand names like "Shantotto" (matches id 896 Shantotto AND
-- id 1019 Shantotto II via party_name) return true if EITHER variant is
-- learned. "SemihLafihna" (no space, party_name form) also resolves.
local function trust_is_owned(name)
    if not name or name == '' then return false end
    local ids = trust_id_by_name[name] or trust_id_by_name[name:lower()]
    if not ids then return false end
    local known = windower.ffxi.get_spells() or {}
    for _, id in ipairs(ids) do
        if known[id] == true then return true end
    end
    return false
end

-- =============================================================================
-- Defaults / settings
-- =============================================================================

local defaults = {
    pos     = { x = 250, y = 250 },
    visible = false,
    delay   = 3.0,   -- seconds between /ma sends (change at runtime with //ft delay <n>)
    -- Spell-name prefix. Retail FFXI uses "Trust: " (with trailing space).
    -- Most private servers (HorizonXI, Eden, etc.) use bare names — leave
    -- this empty in that case. Change at runtime: //ft prefix Trust:
    -- (use one word, no quotes; trailing colon-space added automatically.)
    prefix  = '',
    sets    = T{
        default = L{'Valaineral', 'Mihli Aliapoh', 'Tenzen', 'Adelheid', 'Joachim'},
    },
}
local settings = config.load(defaults)
if type(settings.sets) ~= 'table' then settings.sets = {} end

local function notify(msg, color)
    windower.add_to_chat(color or 207, '[FFXITrusts] '..msg)
end

-- =============================================================================
-- normalize_set: take whatever shape a saved set is in (Lua array, L{} list,
-- or string-keyed table from XML parse) and return a clean 1..N array.
-- Windower's config lib parses <1>..<5> children as string keys "1".."5" in
-- some versions, which breaks #set and ipairs. We fix that here.
-- =============================================================================
local function normalize_set(set)
    if type(set) ~= 'table' then return {} end

    -- If it's already a proper 1..N array, just copy the strings.
    if #set > 0 then
        local out = {}
        for i, v in ipairs(set) do
            if type(v) == 'string' and v ~= '' then out[#out+1] = v end
        end
        if #out > 0 then return out end
    end

    -- Otherwise look for numeric-string keys "1".."N" (or any numeric)
    local pairs_list = {}
    for k, v in pairs(set) do
        local idx = tonumber(k)
        if idx and type(v) == 'string' and v ~= '' then
            pairs_list[idx] = v
        end
    end
    -- Compact into a clean array
    local clean, max = {}, 0
    for k in pairs(pairs_list) do if k > max then max = k end end
    for i = 1, max do
        if pairs_list[i] then clean[#clean+1] = pairs_list[i] end
    end
    return clean
end

-- Walk through every saved set on load and convert it to clean arrays.
local function normalize_all_sets()
    local changed = false
    for name, set in pairs(settings.sets) do
        local clean = normalize_set(set)
        if #clean > 0 then
            settings.sets[name] = clean
            changed = true
        end
    end
    if changed then config.save(settings) end
end
normalize_all_sets()

-- =============================================================================
-- Party introspection
-- =============================================================================

-- Return party-member names that are ACTUALLY trusts (not PCs).
--
-- The original implementation tried `mob.spawn_type == 16` which is
-- backwards — 0x10 / 16 is the spawn_type for mobs, not PCs. Real
-- players (spawn_type 0x01) failed that check and got captured into
-- the saved set as if they were trusts, which then made //ft call try
-- to /ma "PlayerName" and spam the chat with "spell not found."
--
-- Reliable fix: cross-check the name against the trust-name lookup
-- table we already built from res.spells at startup. If the name
-- matches a known Trust spell (`en` or `party_name`, case-insensitive),
-- it's a trust; otherwise skip it.
local function is_known_trust_name(name)
    if not name or name == '' then return false end
    return trust_id_by_name[name] ~= nil
        or trust_id_by_name[name:lower()] ~= nil
end

local function get_current_trusts()
    local party = windower.ffxi.get_party()
    if not party then return {} end
    local trusts, skipped = {}, {}
    for i = 1, 5 do
        local p = party['p'..i]
        if p and p.name and p.name ~= '' then
            if is_known_trust_name(p.name) then
                trusts[#trusts+1] = p.name
            else
                -- Real PC (or some entity not in the trust spell list).
                -- Track for an informational log so the user can see why
                -- their party member was filtered out.
                skipped[#skipped+1] = p.name
            end
        end
    end
    if #skipped > 0 then
        notify('Skipped non-trust party member(s): '..table.concat(skipped, ', '), 167)
    end
    return trusts
end

-- =============================================================================
-- Summon
-- =============================================================================

-- =============================================================================
-- Event-driven summon queue. Instead of a hard-coded wait between trusts,
-- listen for the player's spell-finish action event and advance the queue
-- as soon as the previous trust actually finishes casting. Safety timeout
-- + retry handles failed/interrupted casts.
-- =============================================================================

local summoning = {
    active        = false,
    set_name      = nil,
    queue         = {},
    index         = 0,           -- 1-based index of trust currently being cast
    retries       = 0,
    max_retries   = 1,           -- 1 retry per trust (so 2 attempts total before giving up)
    timeout_token = 0,           -- invalidates pending timeout callbacks
    settle_pause  = 1.2,         -- seconds after spell finish before sending next
    fail_timeout  = 6,           -- seconds to wait for spell to finish before retrying
}

local function spell_for(trust_name)
    local pfx = settings.prefix or ''
    if pfx ~= '' and trust_name:sub(1, #pfx):lower() ~= pfx:lower() then
        return pfx .. trust_name
    end
    return trust_name
end

-- Forward declaration: UI function defined later (after build()) but called
-- from the queue functions below (start, advance, stop). Lua needs the
-- local visible at the call site, even if not yet assigned.
local refresh_action_button = function() end

local function fire_current()
    if not summoning.active then return end
    if summoning.index > #summoning.queue then
        notify('Set "'..summoning.set_name..'" complete!', 158)
        summoning.active = false
        refresh_action_button()
        return
    end

    -- Update the "STOP (i/N)" counter every time we advance to a new trust
    refresh_action_button()

    local trust = summoning.queue[summoning.index]

    -- Skip trusts the character doesn't actually have learned. Without this
    -- guard, attempting to cast (e.g.) Yoran-Oran (UC) when the player
    -- never unlocked it makes /ma fail silently and the queue stalls
    -- through the full retry timeout. Notify and advance immediately.
    if not trust_is_owned(trust) then
        notify('  ['..summoning.index..'/'..#summoning.queue..'] skip "'..trust..'" (not learned)', 167)
        summoning.index   = summoning.index + 1
        summoning.retries = 0
        -- tiny defer so the chat lines come out in order
        coroutine.schedule(fire_current, 0.05)
        return
    end

    -- Don't fire /ma until the player is actually in a state where they can
    -- cast. player.status == 0 (Idle) or 1 (Engaged) means castable; any
    -- other value (2 Dead, 4 Event/cutscene, 33 Chocobo, 44 Mounted, etc.)
    -- means /ma will silently bounce. Defer by 0.5s and try again. The
    -- outer fail_timeout safety net keeps us from looping forever if the
    -- player stays locked.
    local p = windower.ffxi.get_player()
    if not (p and (p.status == 0 or p.status == 1)) then
        coroutine.schedule(fire_current, 0.5)
        return
    end

    local spell = spell_for(trust)
    notify('  ['..summoning.index..'/'..#summoning.queue..'] /ma "'..spell..'" <me>', 158)
    windower.send_command('input /ma "'..spell..'" <me>')

    -- Fixed-timer advance. settings.delay seconds after each /ma, move to
    -- the next trust in the queue regardless of whether the previous one
    -- actually landed. User runs //ft delay <n> to tune the interval.
    -- The token guards against stop_summoning() racing the timer.
    summoning.timeout_token = summoning.timeout_token + 1
    local my_token = summoning.timeout_token
    coroutine.schedule(function()
        if not summoning.active or summoning.timeout_token ~= my_token then return end
        summoning.index = summoning.index + 1
        fire_current()
    end, settings.delay)
end

local function call_set(name)
    if summoning.active then
        notify('Already summoning "'..summoning.set_name..'" ('
                ..summoning.index..'/'..#summoning.queue..'). Run //ft stop to cancel.', 167)
        return
    end
    if not settings.sets[name] then notify('Set "'..name..'" not found.', 167); return end

    local set = normalize_set(settings.sets[name])
    if #set == 0 then
        notify('Set "'..name..'" is empty (no valid member names).', 167)
        return
    end
    settings.sets[name] = set        -- cache cleaned version

    summoning.active        = true
    summoning.set_name      = name
    summoning.queue         = set
    summoning.index         = 1
    summoning.retries       = 0
    summoning.timeout_token = summoning.timeout_token + 1   -- invalidate any stale

    notify('Calling "'..name..'" — '..#set..' trusts ('..settings.delay..'s between casts).')
    refresh_action_button()       -- show Stop button immediately
    fire_current()
end

local function stop_summoning()
    if not summoning.active then notify('Not summoning anything.', 158); return end
    notify('Stopped at '..summoning.index..'/'..#summoning.queue..'. (Any cast already in flight will still finish.)', 167)
    summoning.active        = false
    summoning.timeout_token = summoning.timeout_token + 1   -- invalidate timeout
    refresh_action_button()                                 -- swap Stop → Save
end

-- The queue uses a fixed `settings.delay` timer between casts now, so we
-- no longer need to listen to spell-finish action events to advance.
-- (trust_spell_ids is still built above in case future features want it.)

-- =============================================================================
-- Save flow (two-step: snapshot → name)
-- =============================================================================

local pending_party = nil

local function start_save()
    local trusts = get_current_trusts()
    if #trusts == 0 then
        notify('No trusts in party. Summon them first, then click Save.', 167)
        return
    end
    pending_party = trusts
    notify('Captured: '..table.concat(trusts, ', '))
    notify('Type   //ft savename <name>   to confirm (or //ft cancel to discard).')
end

local function commit_save(name)
    if not pending_party then
        notify('Nothing to save — click Save (or run //ft save) first.', 167)
        return
    end
    settings.sets[name] = pending_party
    config.save(settings)
    notify('Saved "'..name..'": '..table.concat(pending_party, ', '))
    pending_party = nil
    if ui_refresh then ui_refresh() end
end

local function cancel_save()
    pending_party = nil
    notify('Save cancelled.')
end

-- =============================================================================
-- UI — GSUI-style: dark navy bg, cyan section headers, two-panel layout,
-- yellow hover highlight on rows.
-- =============================================================================
-- Layout:
--   +---------------------------------------+
--   | FFXITrusts                          X |   header (rgb 15,25,45)
--   +--------------+------------------------+
--   | Sets    (n)  | Members                |   section headers (cyan)
--   | ^ Up ^       |                        |
--   | • default    | [default]              |
--   | • support    |   • Valaineral         |
--   | • raid       |   • Mihli Aliapoh      |
--   | v Down v     |   • Tenzen             |
--   |              |   ...                  |
--   |              |                        |
--   | + Save       |                        |
--   +--------------+------------------------+

-- Generous spacing — every element gets breathing room
local PANEL_W       = 440                     -- total window width
local LEFT_W        = 180                     -- left column (sets list)
local PAD           = 10                      -- outer padding inside panels
local HEADER_H      = 30                      -- title bar height
local TITLEBAR_GAP  = 10                      -- gap below title bar before section header
local SECTION_H     = 22                      -- section header row height
local SECT_GAP      = 6                       -- gap below section header before list
local LINE_H        = 20                      -- list-row height
local SAVE_BTN_H    = 32                      -- bottom save button
local SAVE_TOP_GAP  = 12                      -- gap above save button
local MAX_VISIBLE   = 10                      -- rows in left list before scroll
local TOTAL_H       = HEADER_H + TITLEBAR_GAP + SECTION_H + SECT_GAP
                      + MAX_VISIBLE * LINE_H + SAVE_TOP_GAP + SAVE_BTN_H + PAD

-- GSUI palette (sampled from screenshots), refined a touch
local C_BG        = { alpha=235, red=8,   green=18,  blue=30  }   -- main bg
local C_HEADER    = { alpha=235, red=18,  green=32,  blue=55  }   -- title bar (slightly brighter)
local C_HEADER_LINE = { alpha=200, red=60, green=110, blue=160 }  -- 1-px line under title
local C_DIVIDER   = { alpha=180, red=40,  green=70,  blue=110 }   -- panel divider
local C_HOVER     = { alpha=160, red=200, green=150, blue=40  }   -- yellow hover
local C_SAVE_BG   = { alpha=210, red=32,  green=70,  blue=42  }   -- save button bg (forest green)
local C_STOP_BG   = { alpha=220, red=110, green=30,  blue=30  }   -- stop button bg (deep red)
local C_STOP_TXT  = { 255, 220, 200 }                              -- stop button text (warm white)
local C_TITLE     = { 130, 210, 240 }                              -- cyan title text
local C_SECT      = { 110, 200, 230 }                              -- section header
local C_SUBTITLE  = { 240, 220, 130 }                              -- "[name] (n)" in right panel (amber)
local C_LIST      = { 225, 225, 230 }                              -- list items
local C_DIM       = { 155, 160, 175 }                              -- dim text
local C_OK        = { 130, 220, 140 }                              -- green button text
local C_CLOSE     = { 230, 170, 170 }                              -- close X
local C_STEP_BG   = { alpha=210, red=40,  green=80,  blue=120 }    -- delay +/- stepper bg
local C_STEP_TXT  = { 255, 255, 255 }                              -- delay +/- stepper text

-- Bounds for the delay-between-trusts stepper. Trust casts take ~6s; the
-- min is forgiving for fast-cast players, the max is just "this is silly."
-- Step half a second per click so the user can dial it in.
local DELAY_MIN  = 1.0
local DELAY_MAX  = 10.0
local DELAY_STEP = 0.5

local function make_bg(x, y, w, h, c)
    return images.new({
        pos   = {x=x, y=y},
        size  = {width=w, height=h},
        color = c,
        draggable = false,
        visible = false,
    })
end

local function make_text(s, x, y, size, rgb, bold)
    local t = texts.new('', {
        pos   = {x=x, y=y},
        text  = {
            font = 'Arial', size = size or 10,
            stroke = {width=1, alpha=200, red=0, green=0, blue=0},
            red = rgb[1], green = rgb[2], blue = rgb[3],
        },
        bg    = {visible=false},
        flags = {bold = bold or false, draggable = false},
        visible = false,
    })
    if s then t:text(s) end
    return t
end

local ui = {
    visible          = false,
    -- elements
    main_bg          = nil,
    header_bg        = nil,
    header_line      = nil,         -- subtle line under title bar
    title_text       = nil,
    close_text       = nil,
    divider          = nil,
    left_sect_text   = nil,         -- "Sets  (n)"
    right_sect_text  = nil,         -- "Members"
    scroll_up        = nil,
    scroll_down      = nil,
    save_bg          = nil,
    save_text        = nil,
    stop_bg          = nil,         -- red Stop button (overlays save while summoning)
    stop_text        = nil,
    summon_bg        = nil,         -- green Summon button (right panel, acts on displayed set)
    summon_text      = nil,
    delete_bg        = nil,         -- red Delete button (right panel, two-click confirm)
    delete_text      = nil,
    delay_label      = nil,         -- "Delay: 3.0s" in the header
    delay_minus_bg   = nil,
    delay_minus_text = nil,
    delay_plus_bg    = nil,
    delay_plus_text  = nil,
    member_texts     = {},
    set_rows         = {},          -- { {bg, text, name, rect}, ... }
    -- state
    scroll           = 0,
    hover_set        = nil,
    selected_set     = nil,
    right_panel_set  = nil,         -- name of set currently rendered on the right
    delete_armed_at  = 0,           -- os.clock() of first delete click; 0 = not armed
    -- rects
    close_rect       = nil,
    save_rect        = nil,
    stop_rect        = nil,
    summon_rect      = nil,
    delete_rect      = nil,
    delay_minus_rect = nil,
    delay_plus_rect  = nil,
    title_rect       = nil,
    scroll_up_rect   = nil,
    scroll_dn_rect   = nil,
    -- drag
    dragging         = false,
    drag_off         = {x=0, y=0},
}

function ui_refresh() end       -- forward decl

-- Y of the first list row (below title bar + gap + section header + gap)
local function list_y()
    return settings.pos.y + HEADER_H + TITLEBAR_GAP + SECTION_H + SECT_GAP
end

-- Y of the section header row (under the title bar)
local function section_y()
    return settings.pos.y + HEADER_H + TITLEBAR_GAP
end

local function compute_member_area_origin()
    return settings.pos.x + LEFT_W + PAD * 2, list_y()
end

local function build()
    local px, py = settings.pos.x, settings.pos.y

    -- Main bg
    ui.main_bg   = make_bg(px, py, PANEL_W, TOTAL_H, C_BG)

    -- Header bar — taller, title vertically centered
    ui.header_bg = make_bg(px, py, PANEL_W, HEADER_H, C_HEADER)
    ui.header_line = make_bg(px, py + HEADER_H, PANEL_W, 1, C_HEADER_LINE)
    ui.title_text  = make_text('FFXITrusts', px + PAD + 4, py + 7, 13, C_TITLE, true)
    ui.close_text  = make_text('X', px + PANEL_W - PAD - 8, py + 6, 13, C_CLOSE, true)
    ui.close_rect  = {x = px + PANEL_W - PAD - 14, y = py + 2, w = PAD + 16, h = HEADER_H - 4}
    ui.title_rect  = {x = px, y = py, w = PANEL_W - PAD - 16, h = HEADER_H}

    -- Delay stepper in the header (right of title, left of close X). Matches
    -- FFXISpammer's TP toggle pattern: "Delay: 3.0s [-] [+]". Adjusts the
    -- settings.delay value live (clamped DELAY_MIN..DELAY_MAX, step 0.5s).
    -- hit_test orders these BEFORE title_rect so clicks here don't fall
    -- through to "start drag."
    local d_btn_w  = 18
    local d_btn_h  = 18
    local d_lbl_w  = 78
    local d_gap    = 4
    local d_btn_y  = py + math.floor((HEADER_H - d_btn_h) / 2)
    local d_plus_x = px + PANEL_W - PAD - 14 - 6 - d_btn_w       -- gap from close-X click rect
    local d_minus_x= d_plus_x - d_gap - d_btn_w
    local d_lbl_x  = d_minus_x - d_gap - d_lbl_w

    ui.delay_label      = make_text(string.format('Delay: %.1fs', settings.delay or 3.0),
                                    d_lbl_x, py + 8, 11, C_LIST, true)
    ui.delay_minus_bg   = make_bg(d_minus_x, d_btn_y, d_btn_w, d_btn_h, C_STEP_BG)
    ui.delay_minus_text = make_text('-', d_minus_x + 6, d_btn_y + 1, 12, C_STEP_TXT, true)
    ui.delay_plus_bg    = make_bg(d_plus_x,  d_btn_y, d_btn_w, d_btn_h, C_STEP_BG)
    ui.delay_plus_text  = make_text('+', d_plus_x + 5,  d_btn_y + 1, 12, C_STEP_TXT, true)
    ui.delay_minus_rect = {x = d_minus_x, y = d_btn_y, w = d_btn_w, h = d_btn_h}
    ui.delay_plus_rect  = {x = d_plus_x,  y = d_btn_y, w = d_btn_w, h = d_btn_h}

    -- Vertical divider between left and right panels
    ui.divider = make_bg(px + LEFT_W, py + HEADER_H + 1, 1,
                         TOTAL_H - HEADER_H - 1, C_DIVIDER)

    -- Section headers (with proper top gap from header bar)
    local sy = section_y()
    ui.left_sect_text  = make_text('Sets',    px + PAD + 2,             sy + 2, 11, C_SECT, true)
    ui.right_sect_text = make_text('Members', px + LEFT_W + PAD * 2,    sy + 2, 11, C_SECT, true)

    -- Scroll indicators
    ui.scroll_up    = make_text('^  Scroll Up  ^',   px + PAD + 18, list_y() + 2,        9, C_DIM)
    ui.scroll_down  = make_text('v  Scroll Down  v', px + PAD + 18, 0,                   9, C_DIM)
    ui.scroll_up_rect = {x = px + PAD, y = list_y(), w = LEFT_W - 2*PAD, h = LINE_H}
    ui.scroll_dn_rect = {x = px + PAD, y = 0,         w = LEFT_W - 2*PAD, h = LINE_H}

    -- Save button — bottom of left panel
    local btn_y = py + TOTAL_H - SAVE_BTN_H - PAD
    ui.save_bg   = make_bg(px + PAD, btn_y, LEFT_W - 2*PAD, SAVE_BTN_H, C_SAVE_BG)
    ui.save_text = make_text('+ Save Current Party',
                             px + PAD + 14, btn_y + 8, 11, C_OK, true)
    ui.save_rect = {x = px + PAD, y = btn_y, w = LEFT_W - 2*PAD, h = SAVE_BTN_H}

    -- Stop button — same slot as Save, only visible while summoning is active.
    -- Created hidden; show_all() / refresh() flip visibility based on state.
    ui.stop_bg   = make_bg(px + PAD, btn_y, LEFT_W - 2*PAD, SAVE_BTN_H, C_STOP_BG)
    ui.stop_text = make_text(string.format('STOP  (%.1fs)', settings.delay or 3.0),
                             px + PAD + 48, btn_y + 8, 11, C_STOP_TXT, true)
    ui.stop_rect = {x = px + PAD, y = btn_y, w = LEFT_W - 2*PAD, h = SAVE_BTN_H}
    ui.stop_bg:hide()
    ui.stop_text:hide()

    -- Right-panel buttons: Summon (green) + Delete (red). Mirror Save's
    -- vertical position so both panels' action rows line up. Buttons stay
    -- hidden until a set is shown on the right (hover or click), at which
    -- point render_members() reveals them.
    local right_x  = px + LEFT_W + PAD
    local right_w  = PANEL_W - LEFT_W - 2 * PAD
    local btn_gap  = 8
    local btn_w    = math.floor((right_w - btn_gap) / 2)
    local del_x    = right_x + btn_w + btn_gap

    ui.summon_bg   = make_bg(right_x, btn_y, btn_w, SAVE_BTN_H, C_SAVE_BG)
    ui.summon_text = make_text('Summon', right_x + 18, btn_y + 8, 11, C_OK, true)
    ui.summon_rect = {x = right_x, y = btn_y, w = btn_w, h = SAVE_BTN_H}

    ui.delete_bg   = make_bg(del_x, btn_y, btn_w, SAVE_BTN_H, C_STOP_BG)
    ui.delete_text = make_text('Delete', del_x + 22, btn_y + 8, 11, C_STOP_TXT, true)
    ui.delete_rect = {x = del_x, y = btn_y, w = btn_w, h = SAVE_BTN_H}

    ui.summon_bg:hide();   ui.summon_text:hide()
    ui.delete_bg:hide();   ui.delete_text:hide()
end

-- Show/hide Stop vs Save depending on whether a summon is in progress.
-- Called when summoning state changes (start/stop/finish) and after refresh.
-- Assigns to the forward-declared local up top.
refresh_action_button = function()
    if not ui.main_bg or not ui.visible then return end
    if summoning.active then
        if ui.save_bg then ui.save_bg:hide() end
        if ui.save_text then ui.save_text:hide() end
        if ui.stop_bg then ui.stop_bg:show() end
        if ui.stop_text then
            ui.stop_text:text(string.format('STOP  (%d/%d)',
                summoning.index, #summoning.queue))
            ui.stop_text:show()
        end
    else
        if ui.stop_bg then ui.stop_bg:hide() end
        if ui.stop_text then ui.stop_text:hide() end
        if ui.save_bg then ui.save_bg:show() end
        if ui.save_text then ui.save_text:show() end
    end
end

local function show_all()
    if not ui.main_bg then build() end
    ui.main_bg:show()
    ui.header_bg:show()
    ui.header_line:show()
    ui.title_text:show()
    ui.close_text:show()
    ui.divider:show()
    ui.left_sect_text:show()
    ui.right_sect_text:show()
    ui.save_bg:show()
    ui.save_text:show()
    -- Delay stepper in the header
    if ui.delay_label      then ui.delay_label:show()      end
    if ui.delay_minus_bg   then ui.delay_minus_bg:show()   end
    if ui.delay_minus_text then ui.delay_minus_text:show() end
    if ui.delay_plus_bg    then ui.delay_plus_bg:show()    end
    if ui.delay_plus_text  then ui.delay_plus_text:show()  end
    -- Show Stop instead of Save if a summon is currently running
    refresh_action_button()
end

local function hide_all()
    if not ui.main_bg then return end
    for _, el in ipairs({ui.main_bg, ui.header_bg, ui.header_line, ui.title_text, ui.close_text,
                         ui.divider, ui.left_sect_text, ui.right_sect_text,
                         ui.scroll_up, ui.scroll_down,
                         ui.save_bg, ui.save_text,
                         ui.stop_bg, ui.stop_text,
                         ui.summon_bg, ui.summon_text,
                         ui.delete_bg, ui.delete_text,
                         ui.delay_label,
                         ui.delay_minus_bg, ui.delay_minus_text,
                         ui.delay_plus_bg, ui.delay_plus_text}) do
        if el then el:hide() end
    end
    for _, row in ipairs(ui.set_rows) do
        if row.bg   then row.bg:hide() end
        if row.text then row.text:hide() end
    end
    for _, t in ipairs(ui.member_texts) do
        t:hide()
    end
end

local function get_sorted_set_names()
    local names = {}
    for name in pairs(settings.sets) do names[#names+1] = name end
    table.sort(names)
    return names
end

-- Hide the right-panel action buttons. Called when nothing is on display
-- (no hover, no selection) or when the set being shown was just deleted.
local function hide_right_buttons()
    if ui.summon_bg   then ui.summon_bg:hide()   end
    if ui.summon_text then ui.summon_text:hide() end
    if ui.delete_bg   then ui.delete_bg:hide()   end
    if ui.delete_text then ui.delete_text:hide() end
    ui.right_panel_set = nil
    ui.delete_armed_at = 0
end

-- Show + label the Summon / Delete buttons for the currently-displayed set.
-- Both act on whatever is on the right panel right now — that's either the
-- hovered row or, when no row is hovered, the last-clicked (selected) row.
-- Only resets the Delete-confirm state when the displayed set CHANGES, so
-- normal mouse movement (which re-runs render_members repeatedly) doesn't
-- disarm a pending "Confirm?" while the user reaches for the button.
local function show_right_buttons(name)
    if not ui.summon_bg then return end
    local changed = (ui.right_panel_set ~= name)
    ui.right_panel_set = name
    ui.summon_bg:show()
    ui.summon_text:show()
    ui.delete_bg:show()
    if changed then
        ui.delete_text:text('Delete')
        ui.delete_armed_at = 0
    end
    ui.delete_text:show()
end

local function render_members(name)
    -- destroy old
    for _, t in ipairs(ui.member_texts) do t:destroy() end
    ui.member_texts = {}

    if not name or not settings.sets[name] then
        hide_right_buttons()
        return
    end

    local mx, my = compute_member_area_origin()
    local set    = settings.sets[name]

    -- Set sub-title in amber: "[Name]   (5)"  — extra top padding for breathing
    local sub_title = '[' .. name .. ']    (' .. #set .. ')'
    local title_t   = make_text(sub_title, mx, my + 2, 12, C_SUBTITLE, true)
    title_t:show()
    table.insert(ui.member_texts, title_t)

    -- Members listed with consistent indent and line height
    for i, trust_name in ipairs(set) do
        local y = my + (LINE_H + 8) + (i - 1) * (LINE_H + 2)
        local t = make_text('    • ' .. trust_name, mx, y, 11, C_LIST)
        t:show()
        table.insert(ui.member_texts, t)
    end

    -- Hint reminds user the click selects (was: auto-summon). Actual
    -- Summon/Delete are the dedicated buttons at the bottom of this panel.
    local hint_y = my + (LINE_H + 8) + #set * (LINE_H + 2) + 12
    local hint   = make_text('(click row to select)', mx, hint_y, 9, C_DIM)
    hint:show()
    table.insert(ui.member_texts, hint)

    show_right_buttons(name)
end

function ui_refresh()
    if not ui.main_bg then return end

    -- tear down old set rows
    for _, row in ipairs(ui.set_rows) do
        if row.bg   then row.bg:destroy()   end
        if row.text then row.text:destroy() end
    end
    ui.set_rows = {}

    local names = get_sorted_set_names()

    -- "Sets  (n)" with extra spacing
    ui.left_sect_text:text('Sets   (' .. #names .. ')')

    -- pagination
    local total = #names
    if ui.scroll < 0 then ui.scroll = 0 end
    if ui.scroll > math.max(0, total - MAX_VISIBLE) then
        ui.scroll = math.max(0, total - MAX_VISIBLE)
    end

    local px = settings.pos.x
    local list_top  = list_y()
    local row_start = list_top

    -- Reserve a row for the "Scroll Up" indicator if needed
    if ui.scroll > 0 then
        ui.scroll_up:pos(px + PAD + 18, list_top + 3)
        ui.scroll_up:show()
        row_start = list_top + LINE_H
    else
        ui.scroll_up:hide()
    end

    -- Draw rows with proper indent and vertical centering
    for slot = 1, MAX_VISIBLE do
        local idx = slot + ui.scroll
        local name = names[idx]
        if not name then break end
        local y = row_start + (slot - 1) * LINE_H

        local row_bg = make_bg(px + PAD, y, LEFT_W - 2*PAD, LINE_H - 2, C_HOVER)
        local row_tx = make_text('  •  ' .. name, px + PAD + 4, y + 2, 11, C_LIST)
        row_tx:show()

        ui.set_rows[slot] = {
            bg = row_bg, text = row_tx, name = name,
            rect = {x = px + PAD, y = y, w = LEFT_W - 2*PAD, h = LINE_H - 2},
        }
    end

    -- "Scroll Down" indicator below the last row
    if ui.scroll + MAX_VISIBLE < total then
        local last_y = row_start + (MAX_VISIBLE - 1) * LINE_H
        local dy = last_y + LINE_H + 2
        ui.scroll_down:pos(px + PAD + 18, dy)
        ui.scroll_dn_rect = {x = px + PAD, y = dy - 2, w = LEFT_W - 2*PAD, h = LINE_H}
        ui.scroll_down:show()
    else
        ui.scroll_down:hide()
    end

    render_members(ui.hover_set or ui.selected_set)
end

local function hit_test(x, y)
    if not ui.visible then return nil end
    local r
    r = ui.close_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='close'} end
    -- Delay stepper sits inside title_rect's bounds — test it FIRST so the
    -- buttons don't fall through to "title click = start drag."
    r = ui.delay_minus_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='delay_minus'} end
    r = ui.delay_plus_rect;  if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='delay_plus'}  end
    -- While summoning is active, the bottom slot is the Stop button. Test
    -- it FIRST so a click during summon doesn't fall through to the Save
    -- rect (same coordinates).
    if summoning.active then
        r = ui.stop_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='stop'} end
    else
        r = ui.save_rect;  if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='save'} end
    end
    -- Summon / Delete are only clickable when a set is being shown on the
    -- right panel (i.e. their backgrounds are visible).
    if ui.right_panel_set then
        r = ui.summon_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='summon'} end
        r = ui.delete_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='delete'} end
    end
    r = ui.scroll_up_rect; if r and ui.scroll > 0 and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='scroll_up'} end
    r = ui.scroll_dn_rect; if r and ui.scroll_down and ui.scroll_down:visible() and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='scroll_down'} end
    for _, row in ipairs(ui.set_rows) do
        local rc = row.rect
        if rc and x >= rc.x and x <= rc.x+rc.w and y >= rc.y and y <= rc.y+rc.h then
            return {type='set', name=row.name}
        end
    end
    r = ui.title_rect; if r and x >= r.x and x <= r.x+r.w and y >= r.y and y <= r.y+r.h then return {type='title'} end
    return nil
end

local function highlight_row(name)
    ui.hover_set = name
    for _, row in ipairs(ui.set_rows) do
        if name and row.name == name then
            row.bg:show()
        else
            row.bg:hide()
        end
    end
    render_members(name or ui.selected_set)
end

local function reposition_all()
    if not ui.main_bg then return end
    local px, py = settings.pos.x, settings.pos.y

    ui.main_bg:pos(px, py)
    ui.header_bg:pos(px, py)
    ui.header_line:pos(px, py + HEADER_H)
    ui.title_text:pos(px + PAD + 4, py + 7)
    ui.close_text:pos(px + PANEL_W - PAD - 8, py + 6)
    ui.close_rect = {x = px + PANEL_W - PAD - 14, y = py + 2, w = PAD + 16, h = HEADER_H - 4}
    ui.title_rect = {x = px, y = py, w = PANEL_W - PAD - 16, h = HEADER_H}

    ui.divider:pos(px + LEFT_W, py + HEADER_H + 1)

    local sy = section_y()
    ui.left_sect_text:pos(px + PAD + 2,          sy + 2)
    ui.right_sect_text:pos(px + LEFT_W + PAD * 2, sy + 2)

    local btn_y = py + TOTAL_H - SAVE_BTN_H - PAD
    ui.save_bg:pos(px + PAD, btn_y)
    ui.save_text:pos(px + PAD + 14, btn_y + 8)
    ui.save_rect = {x = px + PAD, y = btn_y, w = LEFT_W - 2*PAD, h = SAVE_BTN_H}
    if ui.stop_bg then ui.stop_bg:pos(px + PAD, btn_y) end
    if ui.stop_text then ui.stop_text:pos(px + PAD + 48, btn_y + 8) end
    ui.stop_rect = {x = px + PAD, y = btn_y, w = LEFT_W - 2*PAD, h = SAVE_BTN_H}

    -- Right-panel buttons mirror the Save row vertically.
    local right_x = px + LEFT_W + PAD
    local right_w = PANEL_W - LEFT_W - 2 * PAD
    local btn_gap = 8
    local btn_w   = math.floor((right_w - btn_gap) / 2)
    local del_x   = right_x + btn_w + btn_gap

    if ui.summon_bg then ui.summon_bg:pos(right_x, btn_y) end
    if ui.summon_text then ui.summon_text:pos(right_x + 18, btn_y + 8) end
    ui.summon_rect = {x = right_x, y = btn_y, w = btn_w, h = SAVE_BTN_H}

    if ui.delete_bg then ui.delete_bg:pos(del_x, btn_y) end
    if ui.delete_text then ui.delete_text:pos(del_x + 22, btn_y + 8) end
    ui.delete_rect = {x = del_x, y = btn_y, w = btn_w, h = SAVE_BTN_H}

    ui.scroll_up_rect = {x = px + PAD, y = list_y(), w = LEFT_W - 2*PAD, h = LINE_H}

    -- Delay stepper in the header
    local d_btn_w  = 18
    local d_btn_h  = 18
    local d_lbl_w  = 78
    local d_gap    = 4
    local d_btn_y  = py + math.floor((HEADER_H - d_btn_h) / 2)
    local d_plus_x = px + PANEL_W - PAD - 14 - 6 - d_btn_w
    local d_minus_x= d_plus_x - d_gap - d_btn_w
    local d_lbl_x  = d_minus_x - d_gap - d_lbl_w
    if ui.delay_label      then ui.delay_label:pos(d_lbl_x, py + 8) end
    if ui.delay_minus_bg   then ui.delay_minus_bg:pos(d_minus_x, d_btn_y) end
    if ui.delay_minus_text then ui.delay_minus_text:pos(d_minus_x + 6, d_btn_y + 1) end
    if ui.delay_plus_bg    then ui.delay_plus_bg:pos(d_plus_x,  d_btn_y) end
    if ui.delay_plus_text  then ui.delay_plus_text:pos(d_plus_x + 5,  d_btn_y + 1) end
    ui.delay_minus_rect = {x = d_minus_x, y = d_btn_y, w = d_btn_w, h = d_btn_h}
    ui.delay_plus_rect  = {x = d_plus_x,  y = d_btn_y, w = d_btn_w, h = d_btn_h}

    ui_refresh()
end

-- =============================================================================
-- Mouse
-- =============================================================================

-- True if (x, y) is anywhere inside the panel's outer bounding box.
-- Used to block ALL mouse events (including dead space and right-click)
-- from reaching the FFXI game world — otherwise empty clicks inside the
-- panel spin the camera.
local function is_inside_panel(x, y)
    if not ui.visible then return false end
    local px, py = settings.pos.x, settings.pos.y
    return x >= px and x <= px + PANEL_W and y >= py and y <= py + TOTAL_H
end

windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked or not ui.visible then return false end

    local over = is_inside_panel(x, y)

    if mtype == 0 then              -- move
        if ui.dragging then
            settings.pos.x = x - ui.drag_off.x
            settings.pos.y = y - ui.drag_off.y
            reposition_all()
            return true
        end
        if over then
            local hit = hit_test(x, y)
            if hit and hit.type == 'set' then
                if ui.hover_set ~= hit.name then highlight_row(hit.name) end
            elseif ui.hover_set then
                highlight_row(nil)
            end
            return true             -- swallow moves inside panel (no camera rubber-band)
        elseif ui.hover_set then
            highlight_row(nil)
        end
        return false

    elseif mtype == 1 then          -- left click DOWN
        if not over then return false end
        local hit = hit_test(x, y)
        if hit then
            -- Any click that isn't on Delete disarms the two-step confirm
            -- so e.g. user-armed → clicks Summon → later clicks Delete won't
            -- silently nuke the set on a single click.
            if hit.type ~= 'delete' and ui.delete_armed_at ~= 0 then
                ui.delete_armed_at = 0
                if ui.delete_text and ui.right_panel_set then
                    ui.delete_text:text('Delete')
                end
            end
            if hit.type == 'close' then ui.hide()
            elseif hit.type == 'save' then start_save()
            elseif hit.type == 'stop' then stop_summoning()
            elseif hit.type == 'scroll_up'   then ui.scroll = math.max(0, ui.scroll - 1); ui_refresh()
            elseif hit.type == 'scroll_down' then ui.scroll = ui.scroll + 1;              ui_refresh()
            elseif hit.type == 'delay_minus' then
                settings.delay = math.max(DELAY_MIN, (settings.delay or 3.0) - DELAY_STEP)
                config.save(settings)
                if ui.delay_label then
                    ui.delay_label:text(string.format('Delay: %.1fs', settings.delay))
                end
                -- Keep the Stop button's idle-state caption in sync (it
                -- shows "STOP (Xs)" before a summon starts).
                if ui.stop_text and not summoning.active then
                    ui.stop_text:text(string.format('STOP  (%.1fs)', settings.delay))
                end
                notify(string.format('Delay: %.1fs (between trust casts)', settings.delay), 158)
            elseif hit.type == 'delay_plus' then
                settings.delay = math.min(DELAY_MAX, (settings.delay or 3.0) + DELAY_STEP)
                config.save(settings)
                if ui.delay_label then
                    ui.delay_label:text(string.format('Delay: %.1fs', settings.delay))
                end
                if ui.stop_text and not summoning.active then
                    ui.stop_text:text(string.format('STOP  (%.1fs)', settings.delay))
                end
                notify(string.format('Delay: %.1fs (between trust casts)', settings.delay), 158)
            elseif hit.type == 'set' then
                -- Click selects the row but does NOT auto-summon. User then
                -- presses Summon (or Delete) on the right panel to act on it.
                ui.selected_set = hit.name
                render_members(hit.name)
            elseif hit.type == 'summon' then
                if ui.right_panel_set then call_set(ui.right_panel_set) end
            elseif hit.type == 'delete' then
                local name = ui.right_panel_set
                if name and settings.sets[name] then
                    -- Two-click confirm. First click arms the button (label →
                    -- "Confirm?") and starts a 3s timer. Second click while
                    -- armed actually deletes. Click anywhere else or wait it
                    -- out → disarms.
                    local now = os.clock()
                    if ui.delete_armed_at > 0 and (now - ui.delete_armed_at) <= 3.0 then
                        settings.sets[name] = nil
                        config.save(settings)
                        notify('Deleted "'..name..'"', 158)
                        if ui.selected_set == name then ui.selected_set = nil end
                        ui.delete_armed_at = 0
                        ui_refresh()
                        render_members(ui.selected_set)   -- usually nil → hides buttons
                    else
                        ui.delete_armed_at = now
                        if ui.delete_text then ui.delete_text:text('Confirm?') end
                        local my_stamp = now
                        coroutine.schedule(function()
                            if ui.delete_armed_at == my_stamp then
                                ui.delete_armed_at = 0
                                if ui.delete_text and ui.right_panel_set then
                                    ui.delete_text:text('Delete')
                                end
                            end
                        end, 3.1)
                    end
                end
            elseif hit.type == 'title' then
                ui.dragging = true
                ui.drag_off.x = x - settings.pos.x
                ui.drag_off.y = y - settings.pos.y
            end
        end
        return true                 -- block ALL left-down inside the panel (dead-space included)

    elseif mtype == 2 then          -- left release
        if ui.dragging then
            ui.dragging = false
            config.save(settings)
            return true
        end
        if over then return true end
        return false

    elseif mtype == 3 then          -- right click DOWN (FFXI camera grab)
        if over then return true end    -- block — don't grab camera over the panel
        return false

    elseif mtype == 4 then          -- right click UP
        if over then return true end
        return false

    elseif mtype == 5 then          -- middle button down
        if over then return true end
        return false

    elseif mtype == 6 then          -- middle button up
        if over then return true end
        return false

    elseif mtype == 10 then         -- mouse wheel
        if over then
            if delta > 0 then ui.scroll = math.max(0, ui.scroll - 1)
            else              ui.scroll = ui.scroll + 1 end
            ui_refresh()
            return true
        end
        return false
    end

    -- Any other mouse event type — block it if over the panel just to be safe
    if over then return true end
    return false
end)

-- =============================================================================
-- ui:show / hide
-- =============================================================================

ui.show = function()
    show_all()
    ui_refresh()
    ui.visible = true
    settings.visible = true
    config.save(settings)
end

ui.hide = function()
    hide_all()
    ui.visible = false
    settings.visible = false
    config.save(settings)
end

-- =============================================================================
-- Slash commands
-- =============================================================================

windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or ''
    local args = {...}

    if cmd == '' or cmd == 'toggle' then
        if ui.visible then ui.hide() else ui.show() end
    elseif cmd == 'show' then ui.show()
    elseif cmd == 'hide' then ui.hide()

    elseif cmd == 'save' then
        if #args == 0 then
            start_save()
        else
            pending_party = get_current_trusts()
            if #pending_party == 0 then
                notify('No trusts in party.', 167); pending_party = nil
            else
                commit_save(table.concat(args, ' '))
            end
        end
    elseif cmd == 'savename' or cmd == 'name' or cmd == 'confirm' then
        if #args == 0 then notify('Usage: //ft savename <name>', 167); return end
        commit_save(table.concat(args, ' '))
    elseif cmd == 'cancel' then cancel_save()

    elseif cmd == 'call' or cmd == 'summon' or cmd == 'c' then
        if #args == 0 then notify('Usage: //ft call <name>', 167); return end
        call_set(table.concat(args, ' '))

    elseif cmd == 'stop' or cmd == 'abort' then
        stop_summoning()

    elseif cmd == 'delete' or cmd == 'del' or cmd == 'remove' then
        if #args == 0 then notify('Usage: //ft delete <name>', 167); return end
        local name = table.concat(args, ' ')
        if settings.sets[name] then
            settings.sets[name] = nil
            config.save(settings)
            notify('Deleted "'..name..'"'); ui_refresh()
        else notify('No set "'..name..'"', 167) end

    elseif cmd == 'rename' then
        if #args < 2 then notify('Usage: //ft rename <old> <new>', 167); return end
        local oldname = args[1]
        local newname = table.concat(args, ' ', 2)
        if not settings.sets[oldname] then notify('No set "'..oldname..'"', 167); return end
        settings.sets[newname] = settings.sets[oldname]
        settings.sets[oldname] = nil
        config.save(settings)
        notify('Renamed "'..oldname..'" → "'..newname..'"')
        ui_refresh()

    elseif cmd == 'edit' then
        -- //ft edit <setname> <index> <new spell name>
        -- Edit one slot inside a saved set. Useful to fix party-display names
        -- that captured without (UC) suffix etc.
        if #args < 3 then
            notify('Usage: //ft edit <setname> <index> <new name>', 167)
            notify('Example: //ft edit support 1 Yoran-Oran (UC)')
            return
        end
        local setname = args[1]
        local idx = tonumber(args[2])
        local newname = table.concat(args, ' ', 3)
        if not settings.sets[setname] then notify('No set "'..setname..'"', 167); return end
        local set = normalize_set(settings.sets[setname])
        if not idx or idx < 1 or idx > #set then
            notify('Index must be 1-'..#set..' (current size of "'..setname..'")', 167)
            return
        end
        local old = set[idx]
        set[idx] = newname
        settings.sets[setname] = set
        config.save(settings)
        notify('"'..setname..'" slot '..idx..': "'..old..'" → "'..newname..'"')
        ui_refresh()

    elseif cmd == 'list' or cmd == 'ls' then
        local n = 0
        for name, members in pairs(settings.sets) do
            n = n + 1
            notify(n..'. '..name..': '..table.concat(members, ', '))
        end
        if n == 0 then notify('No saved sets.') end

    elseif cmd == 'delay' then
        local d = tonumber(args[1])
        if not d then notify('Current delay: '..settings.delay..'s. Usage: //ft delay <seconds>', 167); return end
        -- Clamp to the same bounds the UI stepper uses so slash and stepper
        -- can't disagree about what's a valid value.
        d = math.max(DELAY_MIN, math.min(DELAY_MAX, d))
        settings.delay = d
        config.save(settings)
        -- Sync the header stepper label + the idle Stop caption
        if ui.delay_label then ui.delay_label:text(string.format('Delay: %.1fs', settings.delay)) end
        if ui.stop_text and not summoning.active then
            ui.stop_text:text(string.format('STOP  (%.1fs)', settings.delay))
        end
        notify('Summon delay set to '..d..'s.')

    elseif cmd == 'prefix' then
        -- //ft prefix          → show current
        -- //ft prefix off      → clear (private server, bare names)
        -- //ft prefix Trust:   → set to "Trust: " (retail)
        if #args == 0 then
            local cur = settings.prefix or ''
            if cur == '' then notify('Prefix: (none)  — bare spell names')
            else notify('Prefix: "'..cur..'"') end
            notify('Usage: //ft prefix off   |   //ft prefix Trust:')
            return
        end
        local v = table.concat(args, ' ')
        if v:lower() == 'off' or v:lower() == 'none' or v == '""' then
            settings.prefix = ''
            notify('Prefix cleared — sending bare spell names.')
        else
            -- normalize: ensure exactly one trailing ": "
            v = v:gsub(':%s*$', '')
            settings.prefix = v..': '
            notify('Prefix set to "'..settings.prefix..'"')
        end
        config.save(settings)

    elseif cmd == 'pos' then
        if #args == 2 then
            settings.pos.x = tonumber(args[1])
            settings.pos.y = tonumber(args[2])
            config.save(settings)
            if ui.visible then reposition_all() end
        else notify('Usage: //ft pos <x> <y>') end

    elseif cmd == 'help' or cmd == '?' then
        notify('Commands:')
        notify('  //ft                     toggle window')
        notify('  //ft show | hide')
        notify('  //ft save                capture current party (then //ft savename)')
        notify('  //ft save <name>         capture + save in one step')
        notify('  //ft savename <name>     commit a staged save')
        notify('  //ft cancel              discard a staged save')
        notify('  //ft call <name>         summon a saved set (auto-advance)')
        notify('  //ft stop                cancel in-progress summoning')
        notify('  //ft delete <name>')
        notify('  //ft rename <old> <new>')
        notify('  //ft edit <set> <slot#> <new name>   (fix one member)')
        notify('  //ft list')
        notify('  //ft pos <x> <y>')
    else
        notify('Unknown command. //ft help for list.', 167)
    end
end)

-- =============================================================================
-- Keyboard — T toggles the window (matches GSUI's B-key pattern).
-- Ignores the press while chat is open so you can still type "T" in messages.
-- =============================================================================

local T_SCANCODE = 0x14         -- DirectInput scan code for T

windower.register_event('keyboard', function(key, pressed, flags, blocked)
    if blocked or not pressed then return end
    if key ~= T_SCANCODE then return end

    local info = windower.ffxi.get_info()
    if info and info.chat_open then return end      -- typing in chat — let the T through

    if ui.visible then ui.hide() else ui.show() end
end)

windower.register_event('load', function()
    notify('v'.._addon.version..' loaded. Press T (or //ft) to open the window.')
    if settings.visible then ui.show() end
end)

windower.register_event('unload', function()
    if ui.main_bg then
        for _, row in ipairs(ui.set_rows) do
            if row.bg then row.bg:destroy() end
            if row.text then row.text:destroy() end
        end
        for _, t in ipairs(ui.member_texts) do t:destroy() end
        for _, el in ipairs({ui.main_bg, ui.header_bg, ui.header_line, ui.title_text, ui.close_text,
                             ui.divider, ui.left_sect_text, ui.right_sect_text,
                             ui.scroll_up, ui.scroll_down,
                             ui.save_bg, ui.save_text,
                             ui.stop_bg, ui.stop_text}) do
            if el then el:destroy() end
        end
    end
end)
