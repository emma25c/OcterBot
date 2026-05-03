-- @name: message_replier
-- @description: Replies to messages based on letter/word/paragraph filters with media support. Configurable via commands.
-- @author: TCT
-- @global: true

-- ============================================================
--  CONFIGURATION GÉNÉRALE
-- ============================================================

-- Préfixe des commandes d'administration
local CMD_PREFIX = "!"

-- Numéros autorisés à utiliser les commandes admin (format: "numero@s.whatsapp.net")
local ADMINS = {
    "33600000000@s.whatsapp.net",  -- remplace par ton numéro
}

-- Délai humain avant réponse (secondes)
local DELAY_MIN = 1
local DELAY_MAX = 3

-- Répondre uniquement en privé (true) ou aussi dans les groupes (false)
local PRIVATE_ONLY = false

-- Chats à ignorer
local IGNORED_CHATS = {
    "status@broadcast",
}

-- ============================================================
--  FILTRES PAR DÉFAUT (modifiables aussi via commandes)
-- ============================================================

-- Initialisation de l'état global (persistant pendant la session du bot)
if not _G.mr_state then
    _G.mr_state = {
        -- Filtres mot/lettre : { trigger, reply, media, case_sensitive }
        letter_filters = {
            {
                trigger = "salut",
                case_sensitive = false,
                reply = "Salut ! 👋 Comment tu vas ?",
                media = nil
            },
            {
                trigger = "photo",
                case_sensitive = false,
                reply = "Voici une image pour toi !",
                media = { type = "image", path = "/sdcard/bot/images/photo.jpg" }
            },
        },
        -- Filtres paragraphe/phrase : mêmes champs, priorité plus haute
        paragraph_filters = {
            {
                trigger = "envoie moi le menu",
                case_sensitive = false,
                reply = "Voici notre menu 📋",
                media = { type = "image", path = "/sdcard/bot/images/menu.jpg" }
            },
        },
        -- File d'attente des réponses
        queue = {},
        processing = false,
    }
end

local state = _G.mr_state

-- ============================================================
--  UTILITAIRES
-- ============================================================

local function is_admin(sender)
    for _, a in ipairs(ADMINS) do
        if sender == a then return true end
    end
    return false
end

local function is_ignored(chat)
    for _, c in ipairs(IGNORED_CHATS) do
        if chat == c then return true end
    end
    return false
end

local function normalize(text, case_sensitive)
    if case_sensitive then return text end
    return text:lower()
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- Cherche dans une liste de filtres
local function match_filter(list, body)
    for _, f in ipairs(list) do
        local haystack = normalize(body, f.case_sensitive)
        local needle   = normalize(f.trigger, f.case_sensitive)
        if haystack:find(needle, 1, true) then
            return f
        end
    end
    return nil
end

-- ============================================================
--  ENVOI DE RÉPONSE
-- ============================================================

local function send_reply(msg, filter)
    local delay = math.random(DELAY_MIN, DELAY_MAX)
    bot.sleep(delay)

    if filter.reply and filter.reply ~= "" then
        bot.reply(msg.chat, filter.reply, msg.id)
    end

    if filter.media then
        local m = filter.media
        if     m.type == "image"    then bot.send_image(msg.chat, m.path, m.caption or "")
        elseif m.type == "video"    then bot.send_video(msg.chat, m.path, m.caption or "")
        elseif m.type == "audio"    then bot.send_audio(msg.chat, m.path)
        elseif m.type == "document" then bot.send_document(msg.chat, m.path, m.caption or "")
        elseif m.type == "sticker"  then bot.send_sticker(msg.chat, m.path)
        else bot.log_warn("[message_replier] Type de média inconnu : " .. tostring(m.type))
        end
    end

    bot.log_info(string.format("[message_replier] Réponse → %s | trigger: \"%s\"", msg.chat, filter.trigger))
end

local function process_queue()
    if state.processing then return end
    state.processing = true
    math.randomseed(bot.get_time_ms())

    while #state.queue > 0 do
        local item = table.remove(state.queue, 1)
        local ok, err = pcall(send_reply, item.msg, item.filter)
        if not ok then
            bot.log_error("[message_replier] Erreur envoi : " .. tostring(err))
        end
    end

    state.processing = false
end

local function enqueue(msg, filter)
    table.insert(state.queue, { msg = msg, filter = filter })
    process_queue()
end

-- ============================================================
--  SYSTÈME DE COMMANDES ADMIN
-- ============================================================

--[[
COMMANDES DISPONIBLES (à taper dans un chat privé avec le bot) :

!aide                         → Affiche cette aide
!liste                        → Liste tous les filtres actifs
!add mot <trigger> | <reply>  → Ajoute un filtre mot/lettre (texte uniquement)
!add phrase <trigger> | <reply> → Ajoute un filtre paragraphe (texte uniquement)
!add mot <trigger> | <reply> | <type_media> | <chemin_media>
!add phrase <trigger> | <reply> | <type_media> | <chemin_media>
!del mot <trigger>            → Supprime un filtre mot par trigger
!del phrase <trigger>         → Supprime un filtre paragraphe par trigger
]]

local HELP_TEXT = [[
📋 *Commandes message_replier*

*!liste* — affiche tous les filtres actifs

*Ajouter un filtre texte :*
!add mot <trigger> | <réponse>
!add phrase <trigger> | <réponse>

*Ajouter un filtre avec média :*
!add mot <trigger> | <réponse> | <type> | <chemin>
!add phrase <trigger> | <réponse> | <type> | <chemin>
→ types : image, video, audio, document, sticker

*Supprimer un filtre :*
!del mot <trigger>
!del phrase <trigger>

*Exemple :*
!add mot bonjour | Coucou ! 👋
!add mot photo | Tiens ! | image | /sdcard/img.jpg
!del mot bonjour
]]

local function cmd_list(msg)
    local lines = {"📌 *Filtres actifs*\n"}
    table.insert(lines, "— *Mots/lettres* —")
    if #state.letter_filters == 0 then
        table.insert(lines, "(aucun)")
    else
        for i, f in ipairs(state.letter_filters) do
            local media_info = f.media and (" [" .. f.media.type .. "]") or ""
            table.insert(lines, string.format("%d. \"%s\" → %s%s", i, f.trigger, f.reply or "(aucune réponse texte)", media_info))
        end
    end
    table.insert(lines, "\n— *Paragraphes/phrases* —")
    if #state.paragraph_filters == 0 then
        table.insert(lines, "(aucun)")
    else
        for i, f in ipairs(state.paragraph_filters) do
            local media_info = f.media and (" [" .. f.media.type .. "]") or ""
            table.insert(lines, string.format("%d. \"%s\" → %s%s", i, f.trigger, f.reply or "(aucune réponse texte)", media_info))
        end
    end
    bot.send_message(msg.chat, table.concat(lines, "\n"))
end

local function cmd_add(msg, args)
    -- args = "mot <trigger> | <reply> [| <type> | <path>]"
    local mode, rest = args:match("^(%S+)%s+(.+)$")
    if not mode or (mode ~= "mot" and mode ~= "phrase") then
        bot.send_message(msg.chat, "❌ Usage : !add mot|phrase <trigger> | <réponse> [| <type_media> | <chemin>]")
        return
    end

    -- Découper par "|"
    local parts = {}
    for part in rest:gmatch("([^|]+)") do
        table.insert(parts, trim(part))
    end

    if #parts < 2 then
        bot.send_message(msg.chat, "❌ Il faut au minimum : <trigger> | <réponse>")
        return
    end

    local new_filter = {
        trigger        = parts[1],
        reply          = parts[2] ~= "" and parts[2] or nil,
        case_sensitive = false,
        media          = nil,
    }

    if #parts >= 4 then
        new_filter.media = { type = parts[3], path = parts[4] }
    end

    local target = (mode == "mot") and state.letter_filters or state.paragraph_filters
    table.insert(target, new_filter)

    local media_info = new_filter.media and (" + média [" .. new_filter.media.type .. "]") or ""
    bot.send_message(msg.chat, string.format("✅ Filtre *%s* ajouté : \"%s\"%s", mode, new_filter.trigger, media_info))
end

local function cmd_del(msg, args)
    local mode, trigger = args:match("^(%S+)%s+(.+)$")
    if not mode or (mode ~= "mot" and mode ~= "phrase") then
        bot.send_message(msg.chat, "❌ Usage : !del mot|phrase <trigger>")
        return
    end

    trigger = trim(trigger)
    local target = (mode == "mot") and state.letter_filters or state.paragraph_filters
    local removed = false

    for i = #target, 1, -1 do
        if target[i].trigger:lower() == trigger:lower() then
            table.remove(target, i)
            removed = true
        end
    end

    if removed then
        bot.send_message(msg.chat, string.format("🗑️ Filtre *%s* supprimé : \"%s\"", mode, trigger))
    else
        bot.send_message(msg.chat, string.format("⚠️ Aucun filtre *%s* trouvé pour : \"%s\"", mode, trigger))
    end
end

local function handle_command(msg, body)
    local cmd_body = trim(body:sub(#CMD_PREFIX + 1))
    local cmd, args = cmd_body:match("^(%S+)%s*(.*)$")
    if not cmd then return end
    cmd = cmd:lower()
    args = trim(args or "")

    if cmd == "aide" or cmd == "help" then
        bot.send_message(msg.chat, HELP_TEXT)
    elseif cmd == "liste" or cmd == "list" then
        cmd_list(msg)
    elseif cmd == "add" then
        cmd_add(msg, args)
    elseif cmd == "del" or cmd == "delete" then
        cmd_del(msg, args)
    else
        bot.send_message(msg.chat, "❓ Commande inconnue. Tape *!aide* pour voir les commandes disponibles.")
    end
end

-- ============================================================
--  POINT D'ENTRÉE
-- ============================================================

function on_message(msg)
    if msg.is_from_me then return end
    if is_ignored(msg.chat) then return end
    if PRIVATE_ONLY and msg.chat:find("@g.us") then return end

    local body = trim(msg.body or "")
    if body == "" then return end

    -- Commandes admin (priorité maximale)
    if body:sub(1, #CMD_PREFIX) == CMD_PREFIX then
        if is_admin(msg.sender) then
            handle_command(msg, body)
        else
            bot.send_message(msg.chat, "⛔ Tu n'es pas autorisé à utiliser les commandes.")
        end
        return
    end

    -- Priorité 1 : filtres paragraphe
    local matched = match_filter(state.paragraph_filters, body)

    -- Priorité 2 : filtres mot/lettre
    if not matched then
        matched = match_filter(state.letter_filters, body)
    end

    if matched then
        enqueue(msg, matched)
    end
end
