const { bot } = require('../lib')

// Mémoire contextuelle locale (JID => tableau des échanges)
const chatMemory = new Map()

// Configuration modifiable dynamiquement via commandes
const SETTINGS = {
	enabled: true,
	apiKey: process.env.AI_API_KEY || '',
	baseUrl: process.env.AI_BASE_URL || 'https://api.openai.com/v1',
	model: process.env.AI_MODEL || 'gpt-4o-mini',
	tone: 'naturel, décontracté, concis, amical',
	rules: [
		'Réponds en 1 à 3 phrases maximum.',
		'Utilise un langage SMS / familier léger (ex: cv, wesh, trkl, tkt, yo).',
		'Ne dis jamais que tu es un bot ou une IA, réponds comme si tu étais le proprio du compte.',
		'Si la question est trop sensible ou financière, dis que tu réponds tout à l’heure.',
	],
	closeFriends: [
		'22890000000@s.whatsapp.net',
	],
	randomMessages: [
		'Yo ! Ça dit quoi ?',
		'Trkl la journée ?',
		'Tu fais quoi de bon ?',
		'Toujours vivant ? Faut qu’on se capte bientôt !',
	],
}

// Fonction d'appel universelle (OpenAI compatible / Custom Base URL)
async function requestAI(messages) {
	if (!SETTINGS.apiKey) {
		throw new Error('Aucune clé API configurée. Tape .setapikey <clé>')
	}

	const url = SETTINGS.baseUrl.replace(/\/+$/, '') + '/chat/completions'

	const res = await fetch(url, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'Authorization': `Bearer ${SETTINGS.apiKey}`,
		},
		body: JSON.stringify({
			model: SETTINGS.model,
			messages: messages,
			temperature: 0.7,
		}),
	})

	if (!res.ok) {
		const errData = await res.text()
		throw new Error(`API Error [${res.status}]: ${errData}`)
	}

	const data = await res.json()
	return data.choices?.[0]?.message?.content?.trim() || null
}

// Routine d'envoi aléatoire aux amis
let cronStarted = false
function initRandomPings(message) {
	if (cronStarted) return
	cronStarted = true

	setInterval(async () => {
		if (SETTINGS.closeFriends.length === 0) return

		const shouldSend = Math.random() < 0.25
		if (!shouldSend) return

		const target =
			SETTINGS.closeFriends[
				Math.floor(Math.random() * SETTINGS.closeFriends.length)
			]
		const randomText =
			SETTINGS.randomMessages[
				Math.floor(Math.random() * SETTINGS.randomMessages.length)
			]

		try {
			await message.client.sendMessage(target, { text: randomText })
			console.log(`[AI Companion] Message aléatoire envoyé à ${target}`)
		} catch (err) {
			console.error('[AI Companion] Erreur ping aléatoire :', err)
		}
	}, 1000 * 60 * 60 * 2)
}

// -------------------------------------------------------------
// 1. GESTION DES COMMANDES DE CONFIGURATION
// -------------------------------------------------------------

bot(
	{
		pattern: 'setapikey ?(.*)',
		fromMe: true,
		desc: 'Définir la clé API de l’IA',
		type: 'ai',
	},
	async (message, match) => {
		if (!match) return await message.sendMessage('_Précise la clé : .setapikey sk-xxxx_')
		SETTINGS.apiKey = match.trim()
		return await message.sendMessage('✅ *Clé API mise à jour avec succès.*')
	}
)

bot(
	{
		pattern: 'setbaseurl ?(.*)',
		fromMe: true,
		desc: 'Définir l’URL de base de l’API (ex: https://openrouter.ai/api/v1)',
		type: 'ai',
	},
	async (message, match) => {
		if (!match) return await message.sendMessage('_Précise l’URL : .setbaseurl https://api.openai.com/v1_')
		SETTINGS.baseUrl = match.trim()
		return await message.sendMessage(`✅ *Base URL mise à jour :* ${SETTINGS.baseUrl}`)
	}
)

bot(
	{
		pattern: 'setmodel ?(.*)',
		fromMe: true,
		desc: 'Définir le modèle d’IA utilisé',
		type: 'ai',
	},
	async (message, match) => {
		if (!match) return await message.sendMessage('_Précise le modèle : .setmodel gpt-4o-mini_')
		SETTINGS.model = match.trim()
		return await message.sendMessage(`✅ *Modèle mis à jour :* ${SETTINGS.model}`)
	}
)

bot(
	{
		pattern: 'aiconfig',
		fromMe: true,
		desc: 'Voir la configuration actuelle de l’IA',
		type: 'ai',
	},
	async (message) => {
		const maskedKey = SETTINGS.apiKey
			? `${SETTINGS.apiKey.slice(0, 4)}...${SETTINGS.apiKey.slice(-4)}`
			: 'Non configurée ❌'

		const configText = `⚙️ *CONFIGURATION IA ACTUELLE*

*Statut :* ${SETTINGS.enabled ? 'ACTIF ✅' : 'DÉSACTIVÉ 🛑'}
*Base URL :* ${SETTINGS.baseUrl}
*Modèle :* ${SETTINGS.model}
*Clé API :* ${maskedKey}

*Commandes utiles :*
• \`.setapikey <clé>\`
• \`.setbaseurl <url>\`
• \`.setmodel <modèle>\`
• \`.autochat on|off\``

		return await message.sendMessage(configText)
	}
)

bot(
	{
		pattern: 'autochat ?(.*)',
		fromMe: true,
		desc: 'Activer ou désactiver l’auto-répondeur IA',
		type: 'ai',
	},
	async (message, match) => {
		const action = match.trim().toLowerCase()
		if (action === 'on') {
			SETTINGS.enabled = true
			return await message.sendMessage('_Auto-répondeur activé ✅_')
		}
		if (action === 'off') {
			SETTINGS.enabled = false
			return await message.sendMessage('_Auto-répondeur désactivé 🛑_')
		}
		return await message.sendMessage(`*Statut :* ${SETTINGS.enabled ? 'ON' : 'OFF'}\n*Usage :* .autochat on | off`)
	}
)

// -------------------------------------------------------------
// 2. RÉPONSE AUTOMATIQUE AUX MESSAGES ENTRINTS (MP)
// -------------------------------------------------------------

bot(
	{
		on: 'text',
		fromMe: false,
		desc: 'Auto-répondeur intelligent en MP',
		type: 'ai',
	},
	async (message) => {
		initRandomPings(message)

		if (!SETTINGS.enabled || message.isGroup || message.fromMe) return
		if (!SETTINGS.apiKey) return

		const senderJid = message.jid
		const userText = message.text

		if (!userText || userText.startsWith('.')) return

		const systemPrompt = `Tu réponds aux messages privés WhatsApp à la place du propriétaire du compte.
Ton comportement :
- Ton : ${SETTINGS.tone}
- Règles strictes : ${SETTINGS.rules.join(' | ')}
Sois direct, fluide et concis.`

		const history = chatMemory.get(senderJid) || []
		const payloadMessages = [
			{ role: 'system', content: systemPrompt },
			...history,
			{ role: 'user', content: userText },
		]

		try {
			await message.client.sendPresenceUpdate('composing', senderJid)

			const reply = await requestAI(payloadMessages)
			if (!reply) return

			// Mise à jour de la mémoire de discussion
			history.push({ role: 'user', content: userText })
			history.push({ role: 'assistant', content: reply })
			if (history.length > 6) history.splice(0, 2)
			chatMemory.set(senderJid, history)

			await new Promise((r) => setTimeout(r, 1200))
			await message.sendMessage(reply)
			await message.client.sendPresenceUpdate('paused', senderJid)
		} catch (error) {
			console.error('[AI Companion] Erreur réponse :', error.message)
		}
	}
)
