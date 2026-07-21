import { runByokModelCommand } from "./commands/byokModel.mjs";

let joinSession;
try {
  ({ joinSession } = await import("@github/copilot-sdk/extension"));
} catch {
  console.error("Copilot SDK is not available. Install the extension into a Copilot CLI environment that provides @github/copilot-sdk/extension.");
  process.exit(1);
}

const session = await joinSession({
  commands: [
    {
      name: "model_byok",
      description: "Select a preloaded BYOK model and switch the current session",
      handler: async (context) => runByokModelCommand(session, context.args ?? ""),
    },
  ],
});

await session.log("BYOK v3 extension loaded.", { level: "info", ephemeral: true });