/*
 * Shared "Connection" section for every Switchboard property inspector: host, port and token as
 * global settings, plus a "Test connection" button that asks the plugin to call /health and /state.
 * Loaded after sdpi-components.js; inserted into #switchboard-connection.
 */
(function () {
	"use strict";

	var mount = document.getElementById("switchboard-connection");
	if (!mount || typeof SDPIComponents === "undefined") return;

	mount.innerHTML =
		'<details style="margin-top: 12px;">' +
		'<summary style="font: 12px/1.6 -apple-system, BlinkMacSystemFont, \'Segoe UI\', sans-serif; color: #c8c8c8; cursor: pointer; padding: 0 6px;">Connection</summary>' +
		'<sdpi-item label="Host">' +
		'<sdpi-textfield setting="host" global placeholder="127.0.0.1"></sdpi-textfield>' +
		"</sdpi-item>" +
		'<sdpi-item label="Port">' +
		'<sdpi-textfield setting="port" global placeholder="48600" pattern="\\d{1,5}" maxlength="5"></sdpi-textfield>' +
		"</sdpi-item>" +
		'<sdpi-item label="Token">' +
		'<sdpi-password setting="token" global placeholder="switchboardctl token"></sdpi-password>' +
		"</sdpi-item>" +
		"<sdpi-item>" +
		'<sdpi-button id="switchboard-test">Test connection</sdpi-button>' +
		"</sdpi-item>" +
		"<sdpi-item>" +
		'<div id="switchboard-test-result" style="font-size: 11px; line-height: 1.4; opacity: 0.85; word-break: break-word;"></div>' +
		"</sdpi-item>" +
		"</details>";

	var client = SDPIComponents.streamDeckClient;
	var button = document.getElementById("switchboard-test");
	var result = document.getElementById("switchboard-test-result");

	button.addEventListener("click", function () {
		result.textContent = "Testing...";
		result.style.color = "";
		client.send("sendToPlugin", { event: "testConnection" });
	});

	client.sendToPropertyInspector.subscribe(function (message) {
		var payload = message && message.payload;
		if (!payload || payload.event !== "testConnection") return;
		result.textContent = payload.message || (payload.ok ? "OK" : "Failed");
		result.style.color = payload.ok ? "#7bd88f" : "#f28b82";
	});
})();
