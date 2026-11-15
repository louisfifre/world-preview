package exploration.preview;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.mojang.serialization.DynamicOps;
import com.mojang.serialization.JsonOps;
import net.minecraft.core.Holder;
import net.minecraft.core.HolderSet;
import net.minecraft.core.Registry;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.RegistryOps;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.levelgen.feature.AbstractOreFeature;
import net.minecraft.world.level.levelgen.feature.Feature;
import net.minecraft.world.level.levelgen.placement.PlacedFeature;
import net.minecraft.world.level.levelgen.placement.PlacementModifier;

/**
 * The ore rules the server ended up with, as the data packs of the game and of every mod wrote
 * them: for each ore placement, what it places and its placement steps, in the same JSON a data
 * pack holds, and for each biome, the placements it lists once every mod has added its own.
 *
 * <p>Nothing is placed and nothing is counted here: the page reads the rules and plays them on a
 * cut. Output: {@code ores.json}.
 */
final class Ores {
	private Ores() {
	}

	static void write(MinecraftServer server, Path out) throws IOException {
		RegistryAccess access = server.registryAccess();
		DynamicOps<JsonElement> ops = RegistryOps.create(JsonOps.INSTANCE, access);
		Registry<PlacedFeature> placed = access.lookupOrThrow(Registries.PLACED_FEATURE);
		Registry<Biome> biomes = access.lookupOrThrow(Registries.BIOME);

		Map<String, Integer> indexOf = new HashMap<>();
		JsonArray placements = new JsonArray();
		placed.listElements().forEach(holder -> {
			Holder<Feature> feature = holder.value().feature();
			if (!(feature.value() instanceof AbstractOreFeature)) {
				return;
			}
			try {
				JsonObject entry = new JsonObject();
				entry.addProperty("id", holder.getRegisteredName());
				entry.addProperty("feature", feature.getRegisteredName());
				entry.add("config", Feature.DIRECT_CODEC.encodeStart(ops, feature.value()).getOrThrow());
				entry.add("placement",
						PlacementModifier.CODEC.listOf().encodeStart(ops, holder.value().placement()).getOrThrow());
				indexOf.put(holder.getRegisteredName(), placements.size());
				placements.add(entry);
			} catch (RuntimeException e) {
				// A rule that cannot be written back is left out rather than losing the others.
				WorldPreview.LOG.warn("World preview (ores): {} left out, {}", holder.getRegisteredName(), e.getMessage());
			}
		});

		JsonObject perBiome = new JsonObject();
		biomes.listElements().forEach(biome -> {
			JsonArray list = new JsonArray();
			for (HolderSet<PlacedFeature> step : biome.value().getGenerationSettings().features()) {
				for (Holder<PlacedFeature> holder : step) {
					Integer index = indexOf.get(holder.getRegisteredName());
					if (index != null) {
						list.add(index);
					}
				}
			}
			perBiome.add(biome.getRegisteredName(), list);
		});

		JsonObject json = new JsonObject();
		json.add("placements", placements);
		json.add("biomes", perBiome);
		Files.writeString(out.resolve("ores.json"), new GsonBuilder().create().toJson(json));
		WorldPreview.LOG.info("World preview (ores): {} placements", placements.size());
	}
}
