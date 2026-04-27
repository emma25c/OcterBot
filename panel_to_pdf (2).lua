--[[
  ╔══════════════════════════════════════════════════════════════╗
  ║        PLUGIN: Panel → PDF  —  Baileys Edition              ║
  ║   Collecte images + textes d'un panel et génère un PDF      ║
  ╚══════════════════════════════════════════════════════════════╝

  ✅ Adapté pour @whiskeysockets/baileys (toutes versions récentes)

  INSTALLATION:
    1.  pip install reportlab pillow
    2.  Copier dans plugins/panel_to_pdf.lua
    3.  Dans ton index.js / handler.js, ajouter :
            const plugin = require('./plugins/panel_to_pdf')   ← si bridge JS
        OU laisser le loader Lua de ton bot l'importer automatiquement.
    4.  Redémarrer le bot.

  STRUCTURE DU MESSAGE BAILEYS (rappel) :
    msg.key.remoteJid          → JID du chat  (ex: 2250XXXXXXXX@s.whatsapp.net)
    msg.key.id                 → ID unique du message
    msg.pushName               → Nom affiché de l'expéditeur
    msg.message.imageMessage   → Présent si c'est une image
    msg.message.imageMessage.caption    → Légende de l'image
    msg.message.imageMessage.mimetype   → "image/jpeg" etc.
    msg.message.conversation   → Texte simple
    msg.message.extendedTextMessage.text → Texte dans une réponse/lien

  COMMANDES :
    .startpanel [titre]      → Démarre la collecte dans ce chat
    .savech <JID ou lien>    → Copie tout un channel vers PDF
    .addtext <texte>         → Ajoute un bloc de texte
    .statuspanel             → Voir ce qui est collecté
    .cancelpanel             → Annuler
    .savepanel               → Générer + envoyer le PDF
    (image envoyée)          → Ajoutée automatiquement si session active

  INSTALLATION :
    .plugin install <url_du_fichier.lua>
]]

-- ══════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ══════════════════════════════════════════════════════════════
local CONFIG = {
  prefix        = ".",
  media_dir     = "/tmp/panel_pdf_media/",
  output_dir    = "/tmp/panel_pdf_output/",
  python_script = "/tmp/panel_pdf_gen.py",
  max_images    = 50,
  max_sessions  = 20,
  session_ttl   = 7200,   -- 2 heures en secondes
  debug         = true,
}

-- ══════════════════════════════════════════════════════════════
-- ÉTAT GLOBAL
-- ══════════════════════════════════════════════════════════════
local sessions = {}   -- sessions[jid] = { title, author, items, created_at, media_dir }

-- ══════════════════════════════════════════════════════════════
-- UTILITAIRES GÉNÉRAUX
-- ══════════════════════════════════════════════════════════════

local function log(level, msg)
  if CONFIG.debug or level == "ERROR" then
    print(string.format("[PanelPDF][%s] %s", level, tostring(msg)))
  end
end

local function now()
  return os.time()
end

local function ensure_dir(path)
  local ret = os.execute("mkdir -p '" .. path .. "'")
  return ret == 0 or ret == true
end

local function safe_name(s)
  return tostring(s):gsub("[^%w%-_%.%s]", "_"):gsub("%s+", "_"):sub(1, 50)
end

local function write_binary_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

-- ══════════════════════════════════════════════════════════════
-- DÉCODAGE DES MESSAGES BAILEYS
-- ══════════════════════════════════════════════════════════════

local function get_jid(msg)
  return msg.key and msg.key.remoteJid or ""
end

local function get_msg_id(msg)
  return msg.key and msg.key.id or ""
end

local function get_sender_name(msg)
  if msg.pushName and msg.pushName ~= "" then
    return msg.pushName
  end
  local jid = get_jid(msg)
  return jid:match("^(.-)@") or jid
end

local function get_text(msg)
  local m = msg.message
  if not m then return "" end
  return m.conversation
      or (m.extendedTextMessage and m.extendedTextMessage.text)
      or (m.imageMessage and m.imageMessage.caption)
      or (m.videoMessage and m.videoMessage.caption)
      or (m.documentMessage and m.documentMessage.caption)
      or ""
end

local function is_image(msg)
  local m = msg.message
  return m ~= nil and m.imageMessage ~= nil
end

local function get_mimetype(msg)
  local m = msg.message
  if m and m.imageMessage then
    return m.imageMessage.mimetype or "image/jpeg"
  end
  return "image/jpeg"
end

local function ext_from_mime(mime)
  if mime:find("png")  then return "png"  end
  if mime:find("webp") then return "webp" end
  if mime:find("gif")  then return "gif"  end
  return "jpg"
end

-- ══════════════════════════════════════════════════════════════
-- TÉLÉCHARGEMENT DE MÉDIA — BAILEYS
-- Les 4 cas couverts selon le type de bridge Lua<->Baileys
-- ══════════════════════════════════════════════════════════════

local function download_and_save_image(sock, msg, dest_dir)
  local mime = get_mimetype(msg)
  local ext  = ext_from_mime(mime)
  local path = dest_dir .. "img_" .. now() .. "_" .. math.random(1000,9999) .. "." .. ext

  -- CAS 1 : sock.downloadMedia(msg) → retourne les bytes directement
  if sock.downloadMedia then
    local data = sock.downloadMedia(msg)
    if data and #data > 0 then
      if write_binary_file(path, data) then
        log("INFO", "Image (CAS1 downloadMedia): " .. path); return path
      end
    end
  end

  -- CAS 2 : _G.downloadMediaMessage exposée globalement (bridge standard Baileys)
  if _G.downloadMediaMessage then
    local data = _G.downloadMediaMessage(msg, "buffer")
    if data and #data > 0 then
      if write_binary_file(path, data) then
        log("INFO", "Image (CAS2 global downloadMediaMessage): " .. path); return path
      end
    end
  end

  -- CAS 3 : msg.media_path déjà écrit sur disque par le bot
  if msg.media_path and msg.media_path ~= "" then
    local ok = os.execute("cp '" .. msg.media_path .. "' '" .. path .. "'")
    if ok == 0 or ok == true then
      log("INFO", "Image (CAS3 media_path): " .. path); return path
    end
  end

  -- CAS 4 : sock.ev / store Baileys (adapter selon ta config)
  if sock.store and sock.store.loadMessage then
    local stored = sock.store.loadMessage(get_jid(msg), get_msg_id(msg))
    if stored and stored.media_path then
      os.execute("cp '" .. stored.media_path .. "' '" .. path .. "'")
      log("INFO", "Image (CAS4 store): " .. path); return path
    end
  end

  log("ERROR", "Aucune méthode de téléchargement disponible.")
  return nil
end

-- ══════════════════════════════════════════════════════════════
-- ENVOI DE MESSAGES — BAILEYS
-- ══════════════════════════════════════════════════════════════

local function baileys_send(sock, jid, content)
  if sock.sendMessage then
    return sock.sendMessage(jid, content)
  end
  if _G.sendMessage then
    return _G.sendMessage(jid, content)
  end
  log("ERROR", "sock.sendMessage introuvable")
end

-- Réponse avec citation (quote) au message original
local function reply(sock, msg, text)
  local jid = get_jid(msg)
  -- Baileys : citer un message = passer contextInfo avec la clé du message original
  baileys_send(sock, jid, {
    text = text,
    contextInfo = {
      stanzaId      = get_msg_id(msg),
      participant   = get_jid(msg),
      quotedMessage = msg.message,
    },
  })
end

-- Réaction emoji sur un message Baileys
local function send_react(sock, msg, emoji)
  baileys_send(sock, get_jid(msg), {
    react = { text = emoji, key = msg.key },
  })
end

-- Envoi d'un fichier PDF dans Baileys
local function send_pdf(sock, jid, pdf_path, filename, caption)
  local f = io.open(pdf_path, "rb")
  if not f then
    log("ERROR", "Impossible de lire le PDF: " .. pdf_path); return false
  end
  local bytes = f:read("*a")
  f:close()

  -- Baileys accepte un Buffer Node.js ou un Uint8Array.
  -- Selon le bridge, on passe soit les bytes bruts, soit le chemin.
  local content = {
    document = bytes,                -- bytes du PDF
    mimetype = "application/pdf",
    fileName = filename,
    caption  = caption or "",
  }

  -- Si ton bridge préfère le chemin (ex: sock.sendFile) :
  if sock.sendFile then
    return sock.sendFile(jid, pdf_path, filename, caption)
  end

  local res = baileys_send(sock, jid, content)
  return res ~= nil and res ~= false
end

-- ══════════════════════════════════════════════════════════════
-- GESTION DES SESSIONS
-- ══════════════════════════════════════════════════════════════

local function get_session(jid)
  local s = sessions[jid]
  if not s then return nil end
  if (now() - s.created_at) > CONFIG.session_ttl then
    sessions[jid] = nil; return nil
  end
  return s
end

local function count_sessions()
  local n = 0; for _ in pairs(sessions) do n = n + 1 end; return n
end

local function create_session(jid, title, author)
  if count_sessions() >= CONFIG.max_sessions then
    return nil, "❌ Trop de sessions actives. Réessaie dans un moment."
  end
  local mdir = CONFIG.media_dir .. safe_name(jid) .. "_" .. now() .. "/"
  ensure_dir(mdir)
  ensure_dir(CONFIG.output_dir)
  sessions[jid] = {
    title      = title,
    author     = author,
    items      = {},
    created_at = now(),
    media_dir  = mdir,
  }
  return sessions[jid], nil
end

local function session_add_image(s, path, caption, sender)
  if #s.items >= CONFIG.max_images then
    return false, "Limite de " .. CONFIG.max_images .. " images atteinte."
  end
  table.insert(s.items, {
    type="image", path=path, caption=caption or "",
    sender=sender or "", timestamp=os.date("%d/%m/%Y %H:%M"),
  })
  return true
end

local function session_add_text(s, text, sender, label)
  table.insert(s.items, {
    type="text", text=text, sender=sender or "",
    label=label or "", timestamp=os.date("%d/%m/%Y %H:%M"),
  })
  return true
end

local function session_stats(s)
  local imgs, txts = 0, 0
  for _, it in ipairs(s.items) do
    if it.type == "image" then imgs = imgs + 1 else txts = txts + 1 end
  end
  return imgs, txts
end

-- ══════════════════════════════════════════════════════════════
-- SCRIPT PYTHON DE GÉNÉRATION PDF
-- ══════════════════════════════════════════════════════════════
local function write_python_script()
  local script = [==[
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys, json, os
from datetime import datetime

try:
    from reportlab.lib.pagesizes import A4
    from reportlab.lib import colors
    from reportlab.lib.units import cm
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY
    from reportlab.platypus import (
        SimpleDocTemplate, Paragraph, Spacer, Image,
        HRFlowable, Table, TableStyle, PageBreak, KeepTogether,
    )
    from PIL import Image as PILImage
except ImportError as e:
    print(f"ERREUR_IMPORT:{e}", file=sys.stderr); sys.exit(1)

C_BRAND   = colors.HexColor("#075E54")
C_ACCENT  = colors.HexColor("#25D366")
C_LIGHT   = colors.HexColor("#ECF7F5")
C_DIVIDER = colors.HexColor("#DCE8E6")
C_TEXT    = colors.HexColor("#1C1C1E")
C_META    = colors.HexColor("#8E8E93")
W, H = A4
MARGIN = 2.0 * cm
CW = W - 2 * MARGIN

def clamp_image(path, mw, mh):
    try:
        with PILImage.open(path) as im:
            iw, ih = im.size
        r = min(mw/iw, mh/ih, 1.0)
        return iw*r, ih*r
    except:
        return mw, mh

class PageDeco:
    def __init__(self, title):
        self.title = title
    def __call__(self, canv, doc):
        canv.saveState()
        canv.setFillColor(C_BRAND)
        canv.rect(0, H-1.5*cm, W, 1.5*cm, fill=1, stroke=0)
        canv.setFillColor(C_ACCENT)
        canv.rect(0, H-1.6*cm, W, 0.1*cm, fill=1, stroke=0)
        canv.setFillColor(colors.white)
        canv.setFont("Helvetica-Bold", 11)
        canv.drawString(MARGIN, H-0.88*cm, self.title)
        canv.setFont("Helvetica", 9)
        canv.drawRightString(W-MARGIN, H-0.88*cm, datetime.now().strftime("%d/%m/%Y"))
        canv.setFillColor(C_LIGHT)
        canv.rect(0, 0, W, 1.1*cm, fill=1, stroke=0)
        canv.setStrokeColor(C_DIVIDER)
        canv.setLineWidth(0.5)
        canv.line(0, 1.1*cm, W, 1.1*cm)
        canv.setFillColor(C_META)
        canv.setFont("Helvetica", 8)
        canv.drawString(MARGIN, 0.42*cm, "Généré par Panel→PDF Bot  ·  @whiskeysockets/baileys")
        canv.drawRightString(W-MARGIN, 0.42*cm, f"Page {doc.page}")
        canv.restoreState()

def S():
    return {
        "title":    ParagraphStyle("t", fontName="Helvetica-Bold", fontSize=28,
                        textColor=C_BRAND, spaceAfter=8, alignment=TA_CENTER, leading=34),
        "sub":      ParagraphStyle("s", fontName="Helvetica", fontSize=12,
                        textColor=C_META, spaceAfter=20, alignment=TA_CENTER),
        "stat":     ParagraphStyle("st", fontName="Helvetica-Bold", fontSize=14,
                        textColor=C_ACCENT, alignment=TA_CENTER, leading=20, spaceAfter=6),
        "section":  ParagraphStyle("sec", fontName="Helvetica-Bold", fontSize=13,
                        textColor=C_BRAND, spaceBefore=18, spaceAfter=8, leading=18),
        "cell":     ParagraphStyle("c", fontName="Helvetica", fontSize=11,
                        textColor=C_TEXT, leading=16, alignment=TA_JUSTIFY),
        "caption":  ParagraphStyle("cap", fontName="Helvetica-Oblique", fontSize=9,
                        textColor=C_META, spaceAfter=10, alignment=TA_CENTER, leading=13),
        "meta":     ParagraphStyle("m", fontName="Helvetica", fontSize=8.5,
                        textColor=C_META, spaceAfter=4, leading=12),
    }

def generate(data):
    title  = data.get("title",  "Panel WhatsApp")
    author = data.get("author", "Bot")
    items  = data.get("items",  [])
    out    = data.get("output")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    deco = PageDeco(title)
    doc  = SimpleDocTemplate(out, pagesize=A4,
               leftMargin=MARGIN, rightMargin=MARGIN,
               topMargin=2.0*cm, bottomMargin=1.4*cm,
               title=title, author=author)
    styles = S()
    story  = []
    MIW, MIH = CW, 13.5*cm

    # Page de couverture
    story.append(Spacer(1, 2.5*cm))
    story.append(Paragraph(title, styles["title"]))
    story.append(HRFlowable(width="50%", thickness=3, color=C_ACCENT,
                            spaceAfter=20, hAlign="CENTER"))
    ni = sum(1 for i in items if i["type"]=="image")
    nt = sum(1 for i in items if i["type"]=="text")
    story.append(Paragraph(f"🖼 {ni} image(s)   ·   📝 {nt} texte(s)   ·   📦 {len(items)} éléments", styles["stat"]))
    story.append(Paragraph(f"Exporté le {datetime.now().strftime('%A %d %B %Y à %H:%M')}", styles["sub"]))
    story.append(Paragraph(f"Par : {author}", styles["sub"]))
    story.append(PageBreak())

    idx = 0
    for item in items:
        if item["type"] == "image":
            idx += 1
            path    = item.get("path","")
            caption = item.get("caption","").strip()
            sender  = item.get("sender","")
            ts      = item.get("timestamp","")
            if not os.path.isfile(path):
                story.append(Paragraph(f"⚠ Image #{idx} introuvable : {path}", styles["meta"]))
                continue
            iw, ih = clamp_image(path, MIW, MIH)
            img = Image(path, width=iw, height=ih); img.hAlign="CENTER"
            parts = [Spacer(1,0.2*cm), img]
            if caption: parts.append(Paragraph(f"📸  {caption}", styles["caption"]))
            if sender or ts:
                parts.append(Paragraph("  ·  ".join(filter(None,[sender,ts])), styles["meta"]))
            parts.append(HRFlowable(width="100%", thickness=0.4, color=C_DIVIDER, spaceBefore=8, spaceAfter=8))
            story.append(KeepTogether(parts))

        elif item["type"] == "text":
            text   = item.get("text","").strip()
            sender = item.get("sender","")
            ts     = item.get("timestamp","")
            label  = item.get("label","").strip()
            if label: story.append(Paragraph(label, styles["section"]))
            if text:
                tbl = Table([[Paragraph(text, styles["cell"])]], colWidths=[CW])
                tbl.setStyle(TableStyle([
                    ("BACKGROUND",(0,0),(-1,-1),C_LIGHT),
                    ("BOX",(0,0),(-1,-1),1.5,C_ACCENT),
                    ("LEFTPADDING",(0,0),(-1,-1),14),
                    ("RIGHTPADDING",(0,0),(-1,-1),14),
                    ("TOPPADDING",(0,0),(-1,-1),12),
                    ("BOTTOMPADDING",(0,0),(-1,-1),12),
                ]))
                story.append(tbl)
            if sender or ts:
                story.append(Paragraph("  ·  ".join(filter(None,[sender,ts])), styles["meta"]))
            story.append(Spacer(1,0.35*cm))

    story.append(Spacer(1,1*cm))
    story.append(HRFlowable(width="100%", thickness=1.5, color=C_BRAND, spaceAfter=10))
    story.append(Paragraph("— Fin du panel —", styles["sub"]))
    doc.build(story, onFirstPage=deco, onLaterPages=deco)
    print(f"OK:{out}")

if __name__ == "__main__":
    if len(sys.argv) < 2: sys.exit(1)
    try:
        generate(json.loads(sys.argv[1]))
    except Exception as e:
        print(f"ERREUR:{e}", file=sys.stderr); sys.exit(1)
]==]
  local f = io.open(CONFIG.python_script, "w")
  if not f then log("ERROR", "Impossible d'écrire le script Python"); return false end
  f:write(script); f:close()
  os.execute("chmod +x " .. CONFIG.python_script)
  log("INFO", "Script Python écrit : " .. CONFIG.python_script)
  return true
end

-- ══════════════════════════════════════════════════════════════
-- ENCODAGE JSON MAISON
-- ══════════════════════════════════════════════════════════════

local function jstr(s)
  s = tostring(s)
  s = s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
  return '"'..s..'"'
end

local function item_json(it)
  if it.type == "image" then
    return ('{"type":"image","path":%s,"caption":%s,"sender":%s,"timestamp":%s}')
           :format(jstr(it.path),jstr(it.caption),jstr(it.sender),jstr(it.timestamp))
  else
    return ('{"type":"text","text":%s,"sender":%s,"label":%s,"timestamp":%s}')
           :format(jstr(it.text),jstr(it.sender),jstr(it.label),jstr(it.timestamp))
  end
end

local function build_json(s, out)
  local parts = {}
  for _,it in ipairs(s.items) do table.insert(parts, item_json(it)) end
  return ('{"title":%s,"author":%s,"output":%s,"items":[%s]}')
         :format(jstr(s.title), jstr(s.author), jstr(out), table.concat(parts,","))
end

-- ══════════════════════════════════════════════════════════════
-- GÉNÉRATION DU PDF
-- ══════════════════════════════════════════════════════════════

local function generate_pdf(session)
  local fname   = safe_name(session.title) .. "_" .. os.time() .. ".pdf"
  local outpath = CONFIG.output_dir .. fname
  local payload = build_json(session, outpath):gsub("'","'\\''")
  local cmd     = "python3 " .. CONFIG.python_script .. " '" .. payload .. "' 2>&1"
  log("INFO", "Appel Python…")
  local h = io.popen(cmd)
  local r = h:read("*a"):gsub("%s+$","")
  h:close()
  log("INFO", "Python → " .. r)
  if r:sub(1,3) == "OK:" then return r:sub(4), nil end
  return nil, r
end

-- ══════════════════════════════════════════════════════════════
-- COMMANDES DU BOT
-- ══════════════════════════════════════════════════════════════

local CMD = {}

CMD["startpanel"] = function(sock, msg, args)
  local jid = get_jid(msg)
  if get_session(jid) then
    reply(sock, msg, "⚠️ Un panel est déjà actif.\n• `.savepanel` → générer le PDF\n• `.cancelpanel` → annuler")
    return
  end
  local title = (args ~= "" and args) or ("Panel du " .. os.date("%d/%m/%Y %H:%M"))
  local s, err = create_session(jid, title, get_sender_name(msg))
  if err then reply(sock, msg, err); return end
  reply(sock, msg,
    "✅ *Panel démarré !*\n\n" ..
    "📌 *Titre :* " .. title .. "\n\n" ..
    "━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
    "🖼  Envoie une *image* → ajoutée automatiquement\n" ..
    "📝  `.addtext <texte>` → bloc de texte\n" ..
    "📡  `.savech <JID>` → importer depuis un channel\n\n" ..
    "📊 `.statuspanel`  ·  📤 `.savepanel`  ·  ❌ `.cancelpanel`"
  )
end

CMD["addtext"] = function(sock, msg, args)
  local jid = get_jid(msg)
  local s   = get_session(jid)
  if not s   then reply(sock, msg, "❌ Aucun panel actif. Lance `.startpanel <titre>`"); return end
  if args=="" then reply(sock, msg, "❌ Usage : `.addtext <ton texte>`"); return end
  session_add_text(s, args, get_sender_name(msg), "")
  local imgs, txts = session_stats(s)
  send_react(sock, msg, "✍️")
  reply(sock, msg, "✅ Texte ajouté !\n📊 " .. imgs .. " image(s) · " .. txts .. " texte(s)")
end

CMD["statuspanel"] = function(sock, msg, args)
  local jid = get_jid(msg)
  local s   = get_session(jid)
  if not s then reply(sock, msg, "ℹ️ Aucun panel actif dans ce chat."); return end
  local imgs, txts = session_stats(s)
  local age  = math.floor((now() - s.created_at) / 60)
  local left = math.floor((CONFIG.session_ttl - (now() - s.created_at)) / 60)
  local lines = {
    "📊 *Status du panel*\n",
    "📌 Titre : *" .. s.title .. "*",
    "👤 Créé par : " .. s.author,
    "🖼  Images : *" .. imgs .. "*",
    "📝 Blocs texte : *" .. txts .. "*",
    "⏱  Âge : " .. age .. " min  (expire dans " .. left .. " min)\n",
    "── Contenu ──",
  }
  for i, it in ipairs(s.items) do
    if i > 15 then table.insert(lines, "  … +" .. (#s.items-15) .. " autres"); break end
    if it.type=="image" then
      table.insert(lines, i..". 🖼 "..(it.caption~="" and it.caption:sub(1,35) or "(sans légende)"))
    else
      table.insert(lines, i..". 📝 "..it.text:sub(1,40)..(#it.text>40 and "…" or ""))
    end
  end
  table.insert(lines, "\n📤 `.savepanel` pour générer le PDF")
  reply(sock, msg, table.concat(lines, "\n"))
end

CMD["cancelpanel"] = function(sock, msg, args)
  local jid = get_jid(msg)
  if not get_session(jid) then reply(sock, msg, "ℹ️ Aucun panel actif."); return end
  local s = sessions[jid]
  if s then os.execute("rm -rf '" .. s.media_dir .. "'") end
  sessions[jid] = nil
  reply(sock, msg, "🗑️ Panel annulé.\nLance `.startpanel <titre>` pour recommencer.")
end

-- ┌─ .savech <JID ou lien> ─────────────────────────────────────
-- Récupère les messages récents d'un channel WhatsApp (newsletter/group)
-- et les injecte dans la session active comme items image/texte.
CMD["savech"] = function(sock, msg, args)
  local jid = get_jid(msg)

  -- 1. Vérifier qu'une session est active
  local s = get_session(jid)
  if not s then
    reply(sock, msg,
      "❌ Lance d'abord `.startpanel <titre>` avant d'importer un channel."
    ); return
  end

  -- 2. Valider l'argument (JID ou lien)
  if args == "" then
    reply(sock, msg,
      "❌ Usage : `.savech <JID ou lien du channel>`\n\n" ..
      "Exemples :\n" ..
      "• `.savech 1234567890@newsletter`\n" ..
      "• `.savech https://whatsapp.com/channel/xxx`"
    ); return
  end

  -- 3. Normaliser le JID / extraire depuis un lien
  local channel_jid = args:match("channel/([%w]+)") -- lien → code
  if channel_jid then
    -- Lien WhatsApp Channel → JID newsletter
    -- Baileys format: <code>@newsletter
    channel_jid = channel_jid .. "@newsletter"
  else
    -- Déjà un JID direct (group ou newsletter)
    channel_jid = args:gsub("%s+", "")
    -- Ajouter @newsletter si c'est un ID numérique sans suffixe
    if not channel_jid:find("@") then
      channel_jid = channel_jid .. "@newsletter"
    end
  end

  log("INFO", "savech → target JID : " .. channel_jid)
  reply(sock, msg, "📡 Connexion au channel `" .. channel_jid .. "`…\nRécupération des messages en cours…")

  -- 4. Récupérer les messages du channel via Baileys
  --    Baileys expose sock.fetchMessagesFromWABox ou sock.loadMessages
  --    selon la version. On essaie les deux.
  local raw_messages = nil

  -- Méthode A : fetchMessages (newsletters Baileys récentes)
  if sock.fetchMessages then
    raw_messages = sock.fetchMessages(channel_jid, 50)
  end

  -- Méthode B : loadMessages depuis le store
  if not raw_messages and sock.store and sock.store.messages then
    local store_msgs = sock.store.messages[channel_jid]
    if store_msgs then
      raw_messages = {}
      for _, m in pairs(store_msgs) do
        table.insert(raw_messages, m)
      end
    end
  end

  -- Méthode C : getNewsletterMessages (API Baileys newsletter)
  if not raw_messages and sock.getNewsletterMessages then
    raw_messages = sock.getNewsletterMessages(channel_jid, { count = 50 })
  end

  if not raw_messages or #raw_messages == 0 then
    reply(sock, msg,
      "⚠️ Aucun message trouvé pour ce channel.\n\n" ..
      "Vérifie :\n" ..
      "• Que le bot *suit* ce channel WhatsApp\n" ..
      "• Que le JID est correct (`" .. channel_jid .. "`)\n" ..
      "• Que ton bot a `makeInMemoryStore` activé"
    ); return
  end

  -- 5. Injecter les messages dans la session
  local added_imgs, added_txts, errors = 0, 0, 0

  for _, ch_msg in ipairs(raw_messages) do
    local m = ch_msg.message
    if not m then goto continue end

    -- Timestamp du message du channel
    local ts = ""
    if ch_msg.messageTimestamp then
      ts = os.date("%d/%m/%Y %H:%M", tonumber(ch_msg.messageTimestamp))
    end
    local sender = ch_msg.pushName or channel_jid:match("^(.-)@") or "Channel"

    -- Image dans le message du channel
    if m.imageMessage then
      local path = download_and_save_image(sock, ch_msg, s.media_dir)
      if path then
        local cap = (m.imageMessage.caption or ""):gsub("^%s+",""):gsub("%s+$","")
        session_add_image(s, path, cap, sender)
        added_imgs = added_imgs + 1
      else
        errors = errors + 1
      end
    end

    -- Texte simple dans le message du channel
    local txt = m.conversation
             or (m.extendedTextMessage and m.extendedTextMessage.text)
    if txt and txt:gsub("%s+","") ~= "" then
      session_add_text(s, txt, sender, "")
      added_txts = added_txts + 1
    end

    ::continue::
  end

  -- 6. Rapport final
  local imgs_total, txts_total = session_stats(s)
  reply(sock, msg,
    "✅ *Import terminé !*\n\n" ..
    "📡 Channel : `" .. channel_jid .. "`\n" ..
    "🖼  Images importées : *" .. added_imgs .. "*\n" ..
    "📝 Textes importés : *" .. added_txts .. "*\n" ..
    (errors > 0 and ("⚠️ Échecs : " .. errors .. "\n") or "") ..
    "\n📊 Total panel : " .. imgs_total .. " image(s) · " .. txts_total .. " texte(s)\n\n" ..
    "📤 `.savepanel` pour générer le PDF"
  )
end

CMD["savepanel"] = function(sock, msg, args)
  local jid = get_jid(msg)
  local s   = get_session(jid)
  if not s then reply(sock, msg, "❌ Aucun panel actif. Lance `.startpanel <titre>`."); return end
  if #s.items == 0 then
    reply(sock, msg, "⚠️ Panel vide ! Ajoute des images ou du texte d'abord."); return
  end
  reply(sock, msg, "⏳ Génération du PDF en cours…")
  local pdf_path, err = generate_pdf(s)
  if not pdf_path then
    reply(sock, msg, "❌ Échec :\n```\n" .. (err or "erreur inconnue") .. "\n```"); return
  end
  local imgs, txts = session_stats(s)
  local caption = string.format(
    "📄 *%s*\n🖼 %d image(s)  ·  📝 %d texte(s)\n%s",
    s.title, imgs, txts, os.date("Généré le %d/%m/%Y à %H:%M")
  )
  local ok = send_pdf(sock, jid, pdf_path, safe_name(s.title)..".pdf", caption)
  if ok then
    os.execute("rm -rf '" .. s.media_dir .. "'")
    os.execute("rm -f '"  .. pdf_path .. "'")
    sessions[jid] = nil
    log("INFO", "Session nettoyée pour " .. jid)
  else
    reply(sock, msg, "⚠️ PDF généré mais envoi échoué.\nChemin : `"..pdf_path.."`")
  end
end

-- ══════════════════════════════════════════════════════════════
-- HANDLER PRINCIPAL
-- ══════════════════════════════════════════════════════════════

local function on_message(sock, msg)
  local jid  = get_jid(msg)
  local text = get_text(msg)

  -- Commandes
  if text:sub(1, #CONFIG.prefix) == CONFIG.prefix then
    local cmd, args = text:sub(#CONFIG.prefix+1):match("^(%S+)%s*(.*)")
    if cmd and CMD[cmd:lower()] then
      CMD[cmd:lower()](sock, msg, args or "")
      return true
    end
  end

  -- Auto-ajout image si session active
  local session = get_session(jid)
  if session and is_image(msg) then
    local path = download_and_save_image(sock, msg, session.media_dir)
    if path then
      local cap = ((msg.message.imageMessage.caption or ""):gsub("^%s+",""):gsub("%s+$",""))
      local ok, err = session_add_image(session, path, cap, get_sender_name(msg))
      if ok then
        local imgs, txts = session_stats(session)
        send_react(sock, msg, "🖼️")
        reply(sock, msg,
          "🖼️ *Image #"..imgs.." ajoutée !*\n"..
          (cap~="" and ("📝 _"..cap.."_\n") or "")..
          "📊 "..imgs.." image(s) · "..txts.." texte(s)\n`.savepanel` pour le PDF"
        )
      else
        reply(sock, msg, "⚠️ "..(err or "Impossible d'ajouter l'image."))
      end
    else
      reply(sock, msg,
        "⚠️ Téléchargement échoué.\n" ..
        "Décommente le bon CAS dans `download_and_save_image()` selon ton bridge."
      )
    end
    return true
  end

  return false
end

-- ══════════════════════════════════════════════════════════════
-- INIT + EXPORT
-- ══════════════════════════════════════════════════════════════

math.randomseed(os.time())
ensure_dir(CONFIG.media_dir)
ensure_dir(CONFIG.output_dir)
write_python_script()
log("INFO", "Plugin panel_to_pdf v2.0 (Baileys) chargé ✓")

return {
  name        = "panel_to_pdf",
  version     = "2.0.0-baileys",
  description = "Collecte images + textes d'un panel WhatsApp → PDF",
  commands    = { "startpanel", "addtext", "statuspanel", "cancelpanel", "savepanel", "savech" },
  on_message  = on_message,
  register    = function(bot)
    for name, fn in pairs(CMD) do
      if bot and bot.addCommand then bot.addCommand(CONFIG.prefix..name, fn) end
    end
  end,
}
