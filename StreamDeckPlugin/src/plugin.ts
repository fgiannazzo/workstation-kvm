import streamDeck from "@elgato/streamdeck";

import { RunAction } from "./actions/run.js";
import { StateAction } from "./actions/state.js";
import { initConnection } from "./connection.js";
import { registerPropertyInspectorHandlers } from "./pi-messages.js";

// "info" keeps the token and request bodies out of the log files; raise to "debug" when needed.
streamDeck.logger.setLevel("info");

streamDeck.actions.registerAction(new RunAction());
streamDeck.actions.registerAction(new StateAction());
registerPropertyInspectorHandlers();

await streamDeck.connect();
await initConnection();
