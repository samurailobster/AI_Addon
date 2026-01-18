@tool
extends EditorPlugin
# HACK: There are several workarounds from porting from Godot +3.x in use. This
# is a target rich environment for optimization and refactoring.

# TODO : Add support for other providers like Ollama, KoboldCpp or cloud models
var server_name := "LM Studio" # Addon was made with LM Studio
var stream := false # The addon does not currently support a streaming response.
var raw := false
var format := "json" # This option ensures that the model will return a JSON readable response.
var post_api := "/v1/chat/completions" # Endpoint for chat generation
var get_api := "/v1/models"# Endpoint for model list request
var local_address := "http://localhost" # Use this or 127.0.0.1 or whatever local address your LLM program uses
var port := 1234
var default_model := ""
var headers := ["Content-Type: application/json"]
var cached_models := []

var cfg := {}

var content := "You are a senior Godot engine developer with many years of professional experience 
specializing exclusively in GDScript 4.x (Godot 4.0 → current version).

You write clean, modern, idiomatic GDScript following current best practices.
You prefer composition over inheritance, favor typed arrays/dictionaries,
use proper signal usage, avoid unnecessary @onready when possible, and write
self-documenting code with good naming.

You always try to write the most maintainable and performant solution 
that makes sense for a real game project (not just the shortest code)."

# Addon variables
var http_request := HTTPRequest.new()
var request_type := ""
var request_in_progress := false
var chat_dock : Control
var settings_menu : Window
var script_editor : CodeEdit
var server_entry : LineEdit
var address_entry : LineEdit
var port_entry : LineEdit
var current_mode : int
var current_line_at_cursor_pos : int
var response_content : String
var body
var prompt : String
var index : int
var llm_server_address : String

var chat_input : TextEdit
var chat_display : RichTextLabel
var send_chat : Button
var send_comment : Button
var send_action : Button
var send_help : Button
var send_optimize: Button
var model_select : OptionButton
var include_script_toggle : CheckBox
var included_script : String
var save_response : bool = false

var model_response_destination = DISPLAY.SCRIPT_EDITOR

const CONFIG_FILE := "res://addons/AI_addon/config.json"
const MODEL_RESPONSES := "res://addons/AI_Addon/model_responses/"

enum modes { ACTION, COMMENT, CHAT, HELP, OPTIMIZE, ANALYZE}
enum DISPLAY { CHAT_DOCK, SCRIPT_EDITOR }
enum CHAT_MSG_TYPE {PLAIN, USER, LLM, CODE, ERROR, STATUS, SYSTEM, DEBUG}

func _ready() -> void:
	load_interface()
	establish_signal_connections()
	load_config()
	define_script_editor()

func define_script_editor():
	# HACK: Had to add a one second delay for get_base_editor() to resolve
	await get_tree().create_timer(1.0).timeout
	script_editor = EditorInterface.get_script_editor().get_current_editor().get_base_editor()

func load_interface() -> void:
	chat_dock.add_child(http_request)
	add_child(settings_menu)
	add_to_chat("AI Addon online!\n", CHAT_MSG_TYPE.SYSTEM)

# Ensure chat dock and settings menu exist; load UI if missing.
func verify_addon():
	if !chat_dock or !settings_menu:
		load_interface()

# Initialize UI elements and dock controls before _ready; must run node refs
# first in tool scripts.
func _enter_tree() -> void:
	var call_settings_menu = Callable(self, "open_settings_menu")
	chat_dock = preload("res://addons/AI_Addon/chat.tscn").instantiate()
	settings_menu = preload("res://addons/AI_Addon/window.tscn").instantiate()
	settings_menu.hide()
	add_tool_menu_item("Local Server Settings...", call_settings_menu)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, chat_dock)
	# ATTENTION: Node references must come before _ready function in tool script!
	establish_node_references()

# Exits the chat tree.
# Removes controls and frees resources when chat_dock exists.
func _exit_tree() -> void:
	if chat_dock:
		remove_control_from_docks(chat_dock)
		chat_dock.queue_free()
		chat_dock = null
		remove_tool_menu_item("Local Server Settings...")
	else:
		return

# Sets up all UI signal connections for HTTP requests, settings, and chat
# dock actions. INFO: This is the only way(?) to setup signals in a plugin.
func establish_signal_connections():
	http_request.connect("request_completed", Callable(self, "parse_request_result").bind(request_type))
	settings_menu.connect("close_requested", Callable(self, "settings_menu_close"))
	settings_menu.get_node("%model_list").connect("item_selected", Callable(self, "model_selected_in_options_button"))
	settings_menu.get_node("%request_model_list").connect("pressed", Callable(self, "get_model_list"))
	chat_dock.get_node("%chat_button").connect("pressed", Callable(self, "_on_chat_button_pressed"))
	chat_dock.get_node("%Action").connect("pressed", Callable(self, "_on_action_button_pressed"))
	chat_dock.get_node("%Help").connect("pressed", Callable(self, "_on_help_button_pressed"))
	chat_dock.get_node("%Comment").connect("pressed", Callable(self, "_on_comment_button_pressed"))
	chat_dock.get_node("%Optimize").connect("pressed", Callable(self, "_on_optimize_button_pressed"))
	chat_dock.get_node("%Script_Analysis").connect("pressed", Callable(self, "_on_script_analysis_button_pressed"))
	chat_dock.get_node("%include_script_toggle").connect("toggled", Callable(self, "_on_include_script_toggled"))

# Fetches UI node references for chat and settings menus using %-prefixed
# paths; avoids hardcoding paths for better maintainability.
func establish_node_references():
	# chat dock
	chat_display = chat_dock.get_node("%chat_display")
	chat_input = chat_dock.get_node("%chat_input")
	send_chat = chat_dock.get_node("%chat_button")
	send_comment = chat_dock.get_node("%Comment")
	send_action = chat_dock.get_node("%Action")
	send_help = chat_dock.get_node("%Help")
	send_optimize = chat_dock.get_node("%Optimize")
	include_script_toggle = chat_dock.get_node("%include_script_toggle")
	# settings menu
	server_entry = settings_menu.get_node("%server_name")
	address_entry = settings_menu.get_node("%local_address")
	port_entry = settings_menu.get_node("%port")
	model_select = settings_menu.get_node("%model_list")

# Loads config from JSON file; uses defaults if missing or invalid. Silently
# fails on read errors, logs issues to chat.
func load_config() -> void:
	add_to_chat("Attempting to load settings...", CHAT_MSG_TYPE.SYSTEM)
	if not FileAccess.file_exists(CONFIG_FILE):
		add_to_chat("Config file not found! Loading defaults...\n", CHAT_MSG_TYPE.SYSTEM)
		add_to_chat("Go to Project, Tools, Local Servers Settings and verify local address!", CHAT_MSG_TYPE.SYSTEM)
		return
	var file := FileAccess.open(CONFIG_FILE, FileAccess.READ)
	if not file:
		add_to_chat("Failed to open config!\n", CHAT_MSG_TYPE.ERROR)
		return
	var parse_result := JSON.parse_string(file.get_as_text())
	if typeof(parse_result) != TYPE_DICTIONARY:
		add_to_chat("Invalid config format!\n", CHAT_MSG_TYPE.ERROR)
		return
	cfg = parse_result as Dictionary
	# Assign directly to member variables with defaults
	server_name     = cfg.get("server_name", "LM Studio")
	local_address   = cfg.get("local_address", "http://localhost")
	port            = int(cfg.get("port", 1234))
	post_api        = cfg.get("post_api", "/v1/chat/completions")
	get_api         = cfg.get("get_api", "/v1/models")
	headers         = cfg.get("headers", ["Content-Type: application/json"])
	stream          = cfg.get("stream", false)
	raw             = cfg.get("raw", false)
	format          = cfg.get("format", "json")
	default_model   = cfg.get("default_model", "")
	cached_models   = cfg.get("cached_models", [])
	add_to_chat("Config file loaded!", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("Creating server address...", CHAT_MSG_TYPE.SYSTEM)
	# display_plugin_settings()

# NOTICE: Displays plugin config settings, skipping empty `cached_models`; logs all
# other key-value pairs as status messages, then initializes LLM server address.
# Currently not used.
func display_plugin_settings() ->void:
	add_to_chat("Local server settings....", CHAT_MSG_TYPE.SYSTEM)
	for each_key in cfg:
		if each_key == "cached_models":
			if cfg[each_key]:
				continue
		add_to_chat(str(each_key) + ": " + str(cfg[each_key]), CHAT_MSG_TYPE.STATUS)
	create_llm_server_address()

# Serialize addon settings to JSON and write them to the given config file,
func save_configuration(config_path: String) -> void:
	# Build a fresh dictionary in one go (no side‑effects on the global `current_settings`).
	var data = {
		"server_name":    server_name,
		"local_address":  local_address,
		"port":           int(port),
		"post_api":       post_api,
		"get_api":        get_api,
		"headers":        headers,
		"stream":         stream,
		"raw":            raw,
		"default_model":  default_model,
		"cached_models":  cached_models,
		"format":         format
	}
	var json_text := JSON.stringify(data, "\t")   # pretty‑print with tabs
	var file: FileAccess = FileAccess.open(config_path, FileAccess.WRITE)
	if not file:
		add_to_chat("Failed to open file for writing: %s" % config_path,
					CHAT_MSG_TYPE.ERROR)
		return
	file.store_string(json_text)
	file.close()

# Handles model selection: prints, fetches the chosen model from cache,
# and logs it to chat.
func model_selected_in_options_button(index: int):
	var selected_model = model_select.get_item_text(index)
	default_model = cached_models[index]
	if default_model == selected_model:
		add_to_chat("Model selected: " + str(default_model) + "\n", CHAT_MSG_TYPE.SYSTEM)

# Opens settings UI, ensures addon is active, shows error if missing,
# then displays and populates the menu.
func open_settings_menu() -> void:
	# Ensure the addon is active before proceeding.
	verify_addon()
	# Abort if the settings menu node is missing.
	if not settings_menu:
		add_to_chat("Settings menu does not exist!", CHAT_MSG_TYPE.ERROR)
		return
	# Show and populate the menu.
	settings_menu.popup_centered()
	if server_entry.text == "" or address_entry.text == "" or port_entry.text == "":
		populate_options()

# Fill UI fields from settings and populate model dropdown if data exists.
func populate_options():
	server_entry.text = server_name
	address_entry.text = local_address
	port_entry.text = str(port)
	if cached_models.is_empty() or model_select.item_count == 0:
		return
	for each in cached_models:
		model_select.add_item(each)
		model_select.select(0)
		default_model = cached_models[0]

func settings_menu_close():
	save_settings()
	settings_menu.hide()

# Saves user-configured server and model settings to disk.
func save_settings() -> void:
	add_to_chat("Saving settings...\n", CHAT_MSG_TYPE.SYSTEM)
	server_name = server_entry.text
	local_address = address_entry.text
	port = int(port_entry.text)
	default_model = cached_models[model_select.get_selected_id()]
	save_configuration(CONFIG_FILE)

# Creates and returns an HTTPRequest with the specified request type; stores
# type in `request_type` for later use.
func create_new_request(type_of_request: String) -> HTTPRequest:
	request_type = type_of_request
	return http_request

func set_request_type(type_of_request: String):
	request_type = type_of_request

# # Fetches available models via GET request; logs errors and updates chat
# UI. Avoids mutating global `llm_server_address`.
func get_model_list() -> void:
	# Prepare request ---------------------------------------------------------
	create_llm_server_address()
	set_request_type("GET")
	if not llm_server_address:
		add_to_chat("No valid address.", CHAT_MSG_TYPE.ERROR)
		return
	# Build full URL once (avoid re‑assigning the global variable)
	var url := "%s%s" % [llm_server_address, get_api]
	add_to_chat("Connecting to %s" % url, CHAT_MSG_TYPE.SYSTEM)
	# Send request ------------------------------------------------------------
	var err := http_request.request(url)
	if err != OK:
		push_error("HTTP request failed (error code %d)." % err)
		add_to_chat("Error with HTTP request!", CHAT_MSG_TYPE.ERROR)

# # Parses model data, fills cache and UI list for both dict (data array)
# and plain array inputs.
func parse_model_list(model_data):
	match typeof(model_data):
		TYPE_DICTIONARY:
			for each_model in model_data["data"]:
				cached_models.append(each_model["id"])
				model_select.add_item(each_model["id"])
		TYPE_ARRAY:
			model_select.clear()
			for each_model in model_data:
				model_select.add_item(str(each_model))

# # Sets LLM server address from input fields or defaults to local host+port;
# logs result.
func create_llm_server_address():
	if address_entry.text == "" and port_entry.text == "":
		llm_server_address = str(local_address + ":" + str(port))
	else:
		llm_server_address = str(address_entry.text) + ":" + str(port_entry.text)
	add_to_chat("Local server: " + str(llm_server_address), CHAT_MSG_TYPE.SYSTEM)

# # Handles HTTP responses: parses JSON, logs errors, updates UI for GET
# model list or extracts POST AI reply.
func parse_request_result(_result, _response_code, _headers, body, _request_type):
	# Called when the HTTP get request is completed.
	var test_json_conv = JSON.new()
	if test_json_conv.parse(body.get_string_from_utf8()) != OK:
		add_to_chat("Invalid server response.", CHAT_MSG_TYPE.ERROR)
		return
	var AI_response = test_json_conv.get_data()
	# add_to_chat(AI_response, CHAT_MSG_TYPE.DEBUG)
	if _response_code == 400:
		add_to_chat("Error received: " + str(AI_response["error"]) +  "\n", CHAT_MSG_TYPE.ERROR)
		return
	match request_type:
		"GET":
			add_to_chat("Model list pulled.\n", CHAT_MSG_TYPE.STATUS)
			cached_models.clear()
			model_select.clear()
			parse_model_list(AI_response)
		"POST":
			var response_content := ""
			if AI_response.has("choices") and AI_response["choices"].size() > 0:
				if AI_response["choices"][0].has("message"):
					if AI_response["choices"][0]["message"].has("content"):
						response_content = AI_response["choices"][0]["message"]["content"]
				else:
					add_to_chat("No detectable model response.\n", CHAT_MSG_TYPE.ERROR)
			if response_content:
				handle_response(response_content)
			else:
				add_to_chat("Could not extract a valid response from the AI.\n", CHAT_MSG_TYPE.ERROR)
	request_in_progress = false

# # Handles AI output: routes response based on mode (chat, summarize, action,
# help, optimize) and inserts it into UI or script.
func handle_response(response_content: String):
	match current_mode:
		modes.CHAT:
			add_to_chat(response_content + "\n", CHAT_MSG_TYPE.LLM)
			if save_response:
				save_code_analysis(response_content)
				save_response = false
		modes.COMMENT:
			var AI_summarization = str(response_content).replace("\n", "")
			response_content = "# "
			var line_length = 70
			var current_line_length = 0
			for each_char in range(AI_summarization.length()):
				if current_line_length >= line_length and AI_summarization[each_char] == " ":
					response_content += "\n# "
					current_line_length = 0
				else:
					response_content += AI_summarization[each_char]
					current_line_length += 1
			match model_response_destination:
				DISPLAY.SCRIPT_EDITOR:
					insert_code_at_cursor(response_content)
				DISPLAY.CHAT_DOCK:
					add_to_chat(response_content, CHAT_MSG_TYPE.LLM)
		modes.ACTION:
					insert_code_at_cursor(response_content)
		modes.HELP:
			add_to_chat(response_content + "\n", CHAT_MSG_TYPE.LLM)
		modes.OPTIMIZE:
			insert_code_at_cursor(response_content)
		modes.ANALYZE:
			add_to_chat(response_content + "\n", CHAT_MSG_TYPE.LLM)
			add_to_chat("Saving to model_response directory.\n", CHAT_MSG_TYPE.SYSTEM)
			if save_response:
				save_code_analysis(response_content)
				save_response = false

# Saves code analysis to a timestamped .md file in MODEL_RESPONSES dir; errors
# if write fails.
func save_code_analysis(code_analysis: String) -> void:
	var timestamp = Time.get_datetime_string_from_system()
	var filename = "%s.md" % timestamp.replace(":", "-").replace(" ", "_")
	var filepath = MODEL_RESPONSES + "/" + filename
	add_to_chat("Saved as: " + filepath + "\n", CHAT_MSG_TYPE.SYSTEM)
	var file: FileAccess = FileAccess.open(filepath, FileAccess.WRITE)
	if not file:
		add_to_chat("Failed to open file for writing: %s" % filepath,
					CHAT_MSG_TYPE.ERROR)
		return
	file.store_string(code_analysis)
	file.close()

# Sends AI prompt via HTTP POST; blocks if request in progress or server
# unset. Uses JSON serialization for payload.
func call_AI(_prompt : String):
	if request_in_progress:
		add_to_chat("HTTP request still processing...\n", CHAT_MSG_TYPE.SYSTEM)
		add_to_chat("Wait for completion.\n", CHAT_MSG_TYPE.SYSTEM)
		return
	if !llm_server_address:
		create_llm_server_address()
	var converted_prompt := JSON.new().stringify(_prompt) # DEPRECATED: str(_prompt).json_escape()
	var ai_prompt = {
		"model": default_model,
		"messages" : [
			{
				"role": "system",
				"content": content
			},
			{ 
				"role": "user", 
				"content": converted_prompt
			}
			],
		"stream": false,
		"raw" : raw,
		"format": format
	}
	# DEPRECATED: body = var_to_str(ai_prompt)
	body = JSON.new().stringify(ai_prompt)
	var error := http_request.request(llm_server_address + str(post_api),headers, HTTPClient.METHOD_POST, body)
	request_in_progress = true
	if error != OK:
		add_to_chat("Request error", CHAT_MSG_TYPE.ERROR)
		add_to_chat("Error is :" + str(error), CHAT_MSG_TYPE.ERROR)
		request_in_progress = false

# # Fetches current script source when toggled; stores it in `included_script`
# or errors if empty.
func _on_include_script_toggled(toggled_on : bool):
	if toggled_on:
		var script_code : String = script_editor.get_base_editor().get_current_script().source_code
		if not script_code:
			add_to_chat("No script available.", CHAT_MSG_TYPE.ERROR)
			return
		included_script = script_code

# # Handles sending user input to AI, validates empty text, updates UI and
# chat log.
func _on_chat_button_pressed():
	# TODO: Add "Attach selected text to chat" function
	if request_in_progress:
		add_to_chat("HTTP request processing...", CHAT_MSG_TYPE.SYSTEM)
		return
	if include_script_toggle and include_script_toggle:
		prompt = chat_input.text + " " + included_script
		include_script_toggle.set_pressed_no_signal(false)
		save_response = true
	prompt = chat_input.text
	if prompt == "":
		add_to_chat("Text input empty!", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.CHAT
	chat_input.text = ""
	add_to_chat("User: " + prompt, CHAT_MSG_TYPE.USER)
	call_AI(prompt)

# # Sends selected comment to AI for GDScript generation and displays the result
# in the script editor.
func _on_action_button_pressed():
	var code_request = get_selected_text()
	if not code_request:
		add_to_chat("No request detected.", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.ACTION
	model_response_destination = DISPLAY.SCRIPT_EDITOR
	set_request_type("POST")
	add_to_chat("Sending code generation request to model: " + str(code_request) + "\n", CHAT_MSG_TYPE.USER)
	call_AI("Code the following in GDScript version +4.x. 
			Return only GDScript compliant code. 
			Your response will go directly into the script editor: " + code_request)

# Handles help request by sending selected code to AI; validates selection,
# sets mode, and formats chat with error checks.
func _on_help_button_pressed():
	var code = get_selected_text()
	if !code:
		add_to_chat("No code selected!", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.HELP
	set_request_type("POST")
	add_to_chat("Troubleshoot this code." + "\n", CHAT_MSG_TYPE.USER)
	add_to_chat("Code: \n", CHAT_MSG_TYPE.CODE)
	add_to_chat(str_to_var(code), CHAT_MSG_TYPE.CODE)
	call_AI("Troubleshoot this GDScript 4.x code: " + code)

# Generates a concise, ≤150‑character comment of the provided GDScript code.
func _on_comment_button_pressed() -> void:
	print("YEP")
	var selected_code = get_selected_text()
	if not selected_code:
		add_to_chat("No code to summarize!", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.COMMENT
	model_response_destination = DISPLAY.SCRIPT_EDITOR
	set_request_type("POST")
	var prompt = str("Generate a very short comment (≤150 chars) for this GDScript version +4.x:\n" + selected_code)
	call_AI(prompt)
	add_to_chat("Sending code to local model for comment...", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("_______________________________________", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("Inserting into script editor...", CHAT_MSG_TYPE.SYSTEM)

# Checks for selected code; if empty, shows error. Otherwise sends code to
# AI for optimization, expecting pure GDScript 4.x output for direct editor
# replacement. ALERT: Always verify model output!
func _on_optimize_button_pressed() -> void:
	var selected_code = get_selected_text()
	if not selected_code:
		add_to_chat("No code to optimize!", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.OPTIMIZE
	model_response_destination = DISPLAY.SCRIPT_EDITOR
	set_request_type("POST")
	var prompt = str("Optimize the following code for GDScript version +4.x:\n" + selected_code)
	add_to_chat("Sending code to local model for optimization...", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("_______________________________________", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("Inserting into script editor...", CHAT_MSG_TYPE.SYSTEM)
	call_AI(prompt)

# # Prepares and submits current GDScript for AI review with focus on Godot
# 4.x best practices. ALERT: Always verify model output!
func _on_script_analysis_button_pressed() -> void:
	var script_code = script_editor.get_base_editor().get_current_script().source_code
	if not script_code:
		add_to_chat("No script available.", CHAT_MSG_TYPE.ERROR)
		return
	current_mode = modes.ANALYZE
	model_response_destination = DISPLAY.CHAT_DOCK
	save_response = true
	set_request_type("POST")
	var prompt = str("Analyze the attached GDScript file. Suggest at least 3 improvements. Ensure all code is compliant with
					 version +4.x of Godot.\n" + script_code)
	add_to_chat("Sending current script to model for analysis...", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("_______________________________________", CHAT_MSG_TYPE.SYSTEM)
	add_to_chat("Waiting for response...", CHAT_MSG_TYPE.SYSTEM)
	call_AI(prompt)

# Returns currently selected text in the editor and logs its length as a
# debug message.
func get_selected_text():
	var selected_text = script_editor.get_selected_text()
	add_to_chat("Selected %d chars of code." % selected_text.length(), CHAT_MSG_TYPE.DEBUG)
	return selected_text

# Inserts `code` above current line at cursor; adds newline before pasting
# to preserve positioning. Assumes valid caret line.
func insert_code_at_cursor(code: String) -> void:
	if not script_editor:
		add_to_chat("No active script editor found!\n", CHAT_MSG_TYPE.ERROR)
		return
	var line = script_editor.get_caret_line()
	script_editor.deselect()
	script_editor.set_line(line - 1, "\n" + code)
	script_editor.set_caret_line(line)

# Formats chat text with color/bold styling based on type, pushes RichTextLabel
# tags, auto-scrolls to bottom. Ensures input is stringified first.
func add_to_chat(text, type: int = CHAT_MSG_TYPE.PLAIN) -> void:
	# Ensure we are working with a string.
	if typeof(text) != TYPE_STRING:
		text = str(text)
	# Determine color and boldness based on the message type.
	var use_bold := false
	var color : Color = Color.WHITE
	match type:
		CHAT_MSG_TYPE.USER:
			color = Color.DEEP_SKY_BLUE
		CHAT_MSG_TYPE.LLM:
			color = Color.DEEP_PINK 
		CHAT_MSG_TYPE.CODE:
			color = Color.GREEN 
			use_bold = true            # Show code in bold for emphasis
		CHAT_MSG_TYPE.ERROR:
			color = Color.ORANGE_RED 
			use_bold = true
		CHAT_MSG_TYPE.STATUS:
			color = Color.TURQUOISE
		CHAT_MSG_TYPE.SYSTEM:
			color = Color.AQUAMARINE
			use_bold = true
		CHAT_MSG_TYPE.DEBUG:
			color = Color.RED
		CHAT_MSG_TYPE.PLAIN:
			color = Color.WHITE
	# Append the new line using RichTextLabel's formatting stack.
	chat_display.push_color(color)
	if use_bold:
		chat_display.push_bold()  # Use built‑in bold font style.
	chat_display.append_text(text)
	# Close any opened tags.
	if use_bold:
		chat_display.pop()          # Pop bold/font
	chat_display.pop()              # Pop color
	# Ensure the label scrolls to show the newest message.
	chat_display.newline()
	chat_display.scroll_to_line(chat_display.get_line_count())
