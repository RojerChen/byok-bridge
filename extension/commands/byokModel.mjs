import { getDataDir, readCache, readState, updateState } from "../lib/shared.mjs";

export async function runByokModelCommand(session, rawArgs = "") {
  const dataDir = getDataDir();
  let state;
  let cache;
  try {
    state = readState(dataDir);
    cache = readCache(dataDir);
  } catch (error) {
    await session.log(error instanceof Error ? error.message : String(error), { level: "error" });
    return;
  }
  if (!state?.providerId) {
    await session.log("No provider state was found. Run the BYOK selector wrapper first.", { level: "error" });
    return;
  }

  const argument = rawArgs.trim().toLowerCase();
  const cacheEntry = cache.caches?.[state.providerId];
  const rawModels = cacheEntry?.models || [];
  const models = rawModels
    .filter((item) => (typeof item === "string" ? true : item?.available !== false))
    .map((item) => (typeof item === "string" ? item : item.id));

  if (argument === "info") {
    await session.log(`Provider: ${state.providerName || state.providerId} | Model: ${state.model || "(not set)"}`, { level: "info" });
    return;
  }

  if (!session.capabilities?.ui?.elicitation) {
    await session.log("Interactive model selection is not available in this CLI host. Use /model_byok info for current state.", { level: "error" });
    return;
  }

  if (models.length === 0) {
    await session.log("No models were loaded yet. Run the BYOK selector wrapper to prefetch models first.", { level: "error" });
    return;
  }

  const selected = await session.ui.select("Select a model", models);
  if (!selected) {
    await session.log("Model selection cancelled.", { level: "info" });
    return;
  }

  try {
    await session.setModel(selected);
  } catch (error) {
    await session.log(`Unable to switch model: ${error instanceof Error ? error.message : String(error)}`, { level: "error" });
    return;
  }

  try {
    updateState(
      (current) => ({ ...(current || state), model: selected, updatedAt: new Date().toISOString() }),
      dataDir
    );
  } catch (error) {
    await session.log(`Model changed, but state could not be saved: ${error instanceof Error ? error.message : String(error)}`, { level: "error" });
    return;
  }
  await session.log(`Selected model: ${selected}`, { level: "info" });
}
