-- open-url.lua — "Open URL" feature for uosc
-- Opens a minimal menu that accepts pasted URLs via Ctrl+V

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local function open_url_menu()
	local menu_data = {
		type = "open-url",
		title = "Open URL",
		footnote = "Ctrl+V to paste a URL, then press Enter",
		items = {
			{
				title = "Paste a URL above...",
				value = "ignore",
				selectable = false,
				italic = true,
				muted = true,
				align = "center",
			},
		},
		on_paste = "script-message open-url-load",
		keep_open = true,
		search_style = "disabled",
	}
	local json = utils.format_json(menu_data)
	mp.commandv("script-message-to", "uosc", "open-menu", json)
end

local function on_url_pasted(url)
	if not url or url == "" then
		mp.osd_message("No URL pasted", 2)
		return
	end

	url = url:gsub("^%s+", ""):gsub("%s+$", "")

	if not url:match("^https?://") and not url:match("^rtsp?://") and not url:match("^mms://") then
		mp.osd_message("Not a valid URL", 3)
		msg.warn("Invalid URL rejected: " .. url)
		return
	end

	msg.info("Opening URL: " .. url)
	mp.osd_message("Loading: " .. url:sub(1, 60) .. (url:len() > 60 and "..." or ""), 5)

	-- Load URL immediately, replacing current playback
	mp.commandv("loadfile", url, "replace")
end

mp.register_script_message("open-url-menu", open_url_menu)
mp.register_script_message("open-url-load", on_url_pasted)

msg.info("open-url.lua loaded")
