local Players = game:GetService("Players")
local LocalizationService = game:GetService("LocalizationService")

local Localization = {}
Localization.__index = Localization

local TRANSLATIONS = {
	en = {
		shop_open = "Skins",
		shop_title = "Skins",
		nickname_placeholder = "Give yourself a name",
		avatar_full_body = "Full body",
		avatar_bust = "Bust",
		avatar_face = "Face",
		equipped = "Equipped",
		equip = "Equip",
		buy = "Buy",
		coins = "Coins",
		score = "Score",
		ping = "Ping",
		level = "Lv",
		map_auto = "Map Auto",
		map_resize = "Map 2x",
	},
	es = {
		shop_open = "Aspectos",
		shop_title = "Aspectos",
		nickname_placeholder = "Date un nombre",
		avatar_full_body = "Cuerpo",
		avatar_bust = "Busto",
		avatar_face = "Cara",
		equipped = "Equipado",
		equip = "Equipar",
		buy = "Comprar",
		coins = "Monedas",
		score = "Puntuación",
		ping = "Ping",
		level = "Nv",
		map_auto = "Mapa Auto",
		map_resize = "Mapa x2",
	},
	pt = {
		shop_open = "Skins",
		shop_title = "Skins",
		nickname_placeholder = "Dê um nome a si",
		avatar_full_body = "Corpo",
		avatar_bust = "Busto",
		avatar_face = "Rosto",
		equipped = "Equipado",
		equip = "Equipar",
		buy = "Comprar",
		coins = "Moedas",
		score = "Pontuação",
		ping = "Ping",
		level = "Nv",
		map_auto = "Mapa Auto",
		map_resize = "Mapa x2",
	},
	fr = {
		shop_open = "Skins",
		shop_title = "Skins",
		nickname_placeholder = "Donnez-vous un nom",
		avatar_full_body = "Corps",
		avatar_bust = "Buste",
		avatar_face = "Visage",
		equipped = "Équipé",
		equip = "Équiper",
		buy = "Acheter",
		coins = "Pièces",
		score = "Score",
		ping = "Ping",
		level = "Niv",
		map_auto = "Carte auto",
		map_resize = "Carte x2",
	},
	id = {
		shop_open = "Skin",
		shop_title = "Skin",
		nickname_placeholder = "Beri dirimu nama",
		avatar_full_body = "Tubuh",
		avatar_bust = "Badan",
		avatar_face = "Wajah",
		equipped = "Terpasang",
		equip = "Pasang",
		buy = "Beli",
		coins = "Koin",
		score = "Skor",
		ping = "Ping",
		level = "Lv",
		map_auto = "Peta Auto",
		map_resize = "Peta 2x",
	},
}

local function normalizeLocaleId(localeId: any): string
	if typeof(localeId) ~= "string" then
		return "en"
	end

	localeId = string.lower(localeId)
	local language = localeId:match("^([a-z]+)")
	if language and TRANSLATIONS[language] then
		return language
	end

	if localeId == "zh-cn" or localeId == "zh-tw" then
		return "en"
	end

	return "en"
end

function Localization.new(playerOrLocaleId)
	local localeId = nil
	if typeof(playerOrLocaleId) == "Instance" and playerOrLocaleId:IsA("Player") then
		localeId = playerOrLocaleId.LocaleId
	else
		localeId = playerOrLocaleId
	end

	if typeof(localeId) ~= "string" or localeId == "" then
		local ok, systemLocaleId = pcall(function()
			return LocalizationService.SystemLocaleId
		end)
		if ok then
			localeId = systemLocaleId
		end
	end

	return setmetatable({
		language = normalizeLocaleId(localeId),
	}, Localization)
end

function Localization:_strings()
	return TRANSLATIONS[self.language] or TRANSLATIONS.en
end

function Localization:text(key: string): string
	local strings = self:_strings()
	return strings[key] or TRANSLATIONS.en[key] or key
end

function Localization:format(key: string, ...)
	local template = self:text(key)
	return string.format(template, ...)
end

function Localization:shopButtonText()
	return self:text("shop_open")
end

function Localization:shopTitleText()
	return self:text("shop_title")
end

function Localization:scoreText(score: number)
	return self:format("score") .. " " .. tostring(score)
end

function Localization:pingText(pingMs: number?)
	if typeof(pingMs) == "number" then
		return self:format("ping") .. " " .. tostring(pingMs) .. " ms"
	end
	return self:format("ping") .. " --"
end

function Localization:coinsText(coins: number)
	return self:format("coins") .. " " .. tostring(coins)
end

function Localization:levelText(level: number)
	return self:format("level") .. " " .. tostring(level)
end

function Localization:buyText(cost: number)
	return self:format("buy") .. " " .. tostring(cost)
end

function Localization:mapButtonText(enabled: boolean, side: number)
	if enabled then
		return self:format("map_resize") .. " " .. tostring(side)
	end
	return self:format("map_auto") .. " " .. tostring(side)
end

return Localization
