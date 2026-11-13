package exploration.preview;

import java.io.IOException;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ForkJoinPool;
import java.util.function.Predicate;
import java.util.function.Supplier;
import java.util.stream.IntStream;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import net.minecraft.core.Holder;
import net.minecraft.core.QuartPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.TagKey;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeResolver;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.ChunkGenerator;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.NoiseSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.densityfunction.DensitySampler;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.densityfunction.ScopedDensityBuffer;

/**
 * Samples the overworld generator on a square grid centred on 0,0.
 *
 * <p>It reads the generator only, never the world: no chunk is generated or loaded. For each grid
 * point it asks two questions the generator can answer from the seed and its settings alone: how
 * high is the ground, and which biome is at the surface. This is the same rule our placement code
 * follows, and it is why a map of 8000 blocks takes seconds instead of the minutes real chunks need.
 *
 * <p>Several passes over the same square, from coarse to full, so the page can show a sketch of the
 * map that gets finer while the full one is computed. Output, in the given folder:
 * {@code preview.json} (grid description and biome list), {@code heights.bin} (one little-endian
 * int16 per point, row by row, north to south) and {@code biomes.bin} (one little-endian uint16 per
 * point: an index into the biome list). Each coarse pass writes the same three files under other
 * names: {@code coarse-<step>-heights.bin} and {@code coarse-<step>-biomes.bin}, then
 * {@code coarse.json}, which each pass replaces. The step in the binary names keeps a reader of
 * {@code coarse.json} from pairing it with the files of another pass.
 */
final class Sampler {
	/** Grid points per side of a tile, the square of columns that shares one noise chunk. */
	private static final int TILE = 16;
	/**
	 * The coarse passes, in order: each keeps one point in that many of the full grid along each side.
	 * Each costs about a quarter of the next or less, so the whole ladder adds little to the wait.
	 */
	private static final int[] COARSE = {16, 4, 2};
	/** A coarse pass with fewer points a side than this shows too little to be worth its picture. */
	private static final int COARSE_MIN = 128;
	/** The biomes found under the ground only, by the tag the mods share. */
	private static final TagKey<Biome> UNDERGROUND = TagKey.create(Registries.BIOME,
			Identifier.fromNamespaceAndPath("c", "is_underground"));

	private Sampler() {
	}

	/**
	 * What every column needs, read once from the generator. {@code dry} is the generator's settings
	 * without aquifers, for the coarse pass.
	 */
	record Generator(ServerLevel level, NoiseBasedChunkGenerator generator, NoiseGeneratorSettings settings,
			NoiseGeneratorSettings dry, NoiseSettings noise, RandomState randomState,
			Supplier<Aquifer.FluidPicker> fluidPicker) {
	}

	/** One pass: the ground height and the surface biome of each point. */
	record Grid(int samples, int step, int origin, short[] heights, Holder<Biome>[] biomes, long millis) {
	}

	// disableMobGeneration() is deprecated; it is only passed through to the copy of the settings.
	@SuppressWarnings("deprecation")
	static void run(MinecraftServer server, Path out, int samples, int step) throws IOException {
		ServerLevel level = server.overworld();
		ChunkGenerator chunkGenerator = level.getChunkSource().getGenerator();
		if (!(chunkGenerator instanceof NoiseBasedChunkGenerator generator)) {
			throw new IllegalStateException("The overworld generator is not a noise generator: " + chunkGenerator);
		}
		NoiseGeneratorSettings settings = generator.generatorSettings().value();
		NoiseGeneratorSettings dry = new NoiseGeneratorSettings(settings.noiseSettings(), settings.defaultBlock(),
				settings.defaultFluid(), settings.noiseRouter(), settings.materialRule(), settings.spawnTarget(),
				settings.seaLevel(), settings.disableMobGeneration(), Optional.empty(),
				settings.useLegacyRandomSource(), settings.debugFunctions());
		Generator source = new Generator(level, generator, settings, dry,
				settings.noiseSettings().clampToHeightAccessor(level),
				level.getChunkSource().randomState(), fluidPicker(generator));

		int origin = -(samples * step) / 2;
		Files.createDirectories(out);
		// The passes run on a pool of their own rather than on the JVM's shared one, which takes every
		// core: a full pass lasts minutes, and with all cores busy the machine, the page that shows the
		// sketch included, stops answering.
		ForkJoinPool pool = new ForkJoinPool(threads());
		WorldPreview.LOG.info("World preview: {} threads of {}", pool.getParallelism(),
				Runtime.getRuntime().availableProcessors());
		try {
			Grid full = run(out, source, pool, samples, step, origin);
			// What comes with the map. The map is already written: trouble here must not lose it.
			try {
				Section.write(out, source, full, pool);
				Ores.write(server, out);
			} catch (Exception e) {
				WorldPreview.LOG.error("World preview: no section", e);
			}
			// A try of its own: trouble with the cuts must not lose the structures, nor the reverse.
			try {
				Structures.write(server, out, source, full, pool);
			} catch (Exception e) {
				WorldPreview.LOG.error("World preview: no structures", e);
			}
		} finally {
			pool.shutdown();
		}
	}

	/**
	 * How many threads sample: {@code -Dworldpreview.threads} when given, else half of what the machine
	 * has. Half leaves a core in two to whatever else the person is doing, on any machine, and on the
	 * usual processor with two threads per core it is one thread per real core.
	 */
	private static int threads() {
		int asked = Integer.getInteger("worldpreview.threads", 0);
		return asked > 0 ? asked : Math.max(1, Runtime.getRuntime().availableProcessors() / 2);
	}

	private static Grid run(Path out, Generator source, ForkJoinPool pool, int samples, int step, int origin)
			throws IOException {
		// A coarse pass covers the same square with a longer step. It leaves the aquifers out: setting
		// one up looks for the surface level all over the area its columns cover, so its cost follows
		// the area, not the number of points, and with aquifers a pass of one point in four would cost
		// 40% of the full pass instead of 7% (measured). Without them, the ground is the first block
		// where the density is solid, which misses only the stone walls aquifers put between water and
		// caves (on seed cap-1, all 16384 heights of such a pass came out the same either way). So a
		// sketch is close, not proven exact, and the full pass computes its points again rather than
		// reusing them.
		for (int coarse : COARSE) {
			if (samples % coarse == 0 && samples / coarse >= COARSE_MIN) {
				write(out, "coarse", source, sample(source, pool, samples / coarse, step * coarse, origin, false));
			}
		}
		Grid full = sample(source, pool, samples, step, origin, true);
		write(out, "preview", source, full);
		return full;
	}

	/**
	 * The fluid picker the generator itself uses: Tectonic replaces the vanilla one (it moves the lava
	 * level), so it is read from the generator instead of being built again.
	 */
	@SuppressWarnings("unchecked")
	private static Supplier<Aquifer.FluidPicker> fluidPicker(NoiseBasedChunkGenerator generator) {
		try {
			Field field = NoiseBasedChunkGenerator.class.getDeclaredField("globalFluidPicker");
			field.setAccessible(true);
			return (Supplier<Aquifer.FluidPicker>) field.get(generator);
		} catch (ReflectiveOperationException e) {
			throw new IllegalStateException("Cannot read the generator's fluid picker", e);
		}
	}

	/** One pass, with the aquifers when {@code exact}, as the generator does. */
	private static Grid sample(Generator source, ForkJoinPool pool, int samples, int step, int origin,
			boolean exact) {
		long started = System.nanoTime();
		short[] heights = new short[samples * samples];
		@SuppressWarnings("unchecked")
		Holder<Biome>[] biomes = new Holder[samples * samples];

		// The square is cut into tiles of TILE x TILE points, sampled each in one go, and every
		// thread of the pool takes its share of tiles (the generator is safe to query from several
		// threads: Distant Horizons does the same). A parallel stream started from inside a pool runs
		// on that pool, hence the submit.
		NoiseGeneratorSettings settings = exact ? source.settings() : source.dry();
		int tiles = (samples + TILE - 1) / TILE;
		pool.submit(() -> IntStream.range(0, tiles * tiles).parallel().forEach(tile -> {
			int col0 = (tile % tiles) * TILE, row0 = (tile / tiles) * TILE;
			sampleTile(source, settings, samples, step, origin, col0, row0,
					Math.min(TILE, samples - col0), Math.min(TILE, samples - row0), heights);
		})).join();

		// The biomes come after, row by row from west to east, as before the tiles. The order matters:
		// the biome source remembers, per thread, the biome it found last and starts its next search
		// from it, so where two biomes fit a point equally well, the one found first wins. Read in
		// another order, a few points in a hundred thousand change biome.
		int seaLevel = source.generator().getSeaLevel();
		pool.submit(() -> IntStream.range(0, samples).parallel().forEach(row -> {
			BiomeResolver resolver = source.generator().getBiomeSource().createUncachedResolver(source.randomState());
			int z = origin + row * step;
			for (int col = 0; col < samples; col++) {
				int x = origin + col * step, i = row * samples + col;
				// The biome is read at the surface (the water surface over a sea), not underground,
				// so cave biomes never show up on the map.
				int surface = Math.max(heights[i], seaLevel);
				biomes[i] = resolver.getNoiseBiome(
						QuartPos.fromBlock(x), QuartPos.fromBlock(surface), QuartPos.fromBlock(z));
			}
		})).join();
		return new Grid(samples, step, origin, heights, biomes, (System.nanoTime() - started) / 1_000_000);
	}

	/**
	 * The ground height of a tile of points, the way {@code NoiseBasedChunkGenerator.getBaseHeight}
	 * finds it for one column, but for all the columns of the tile at once.
	 *
	 * <p>{@code getBaseHeight} builds a noise chunk one block wide and the full height of the world,
	 * evaluates the final density of the whole column, then walks it down from the top until the
	 * aquifer says a block is solid. Half of its time goes to setting up that noise chunk: its aquifer
	 * looks for the surface level all around the column, and the columns of neighbouring points look
	 * at the same places again (measured with a profiler, see the commit). Here one noise chunk covers
	 * the tile, its columns {@code step} blocks apart, so that setting up is done once per tile; the
	 * density and the walk down stay those of vanilla, column by column. The heights and biomes files
	 * of a whole preview came out byte for byte the same as with {@code getBaseHeight}.
	 */
	private static void sampleTile(Generator source, NoiseGeneratorSettings settings, int samples, int step,
			int origin, int col0, int row0, int sizeX, int sizeZ, short[] heights) {
		ServerLevel level = source.level();
		NoiseSettings noise = source.noise();
		// OCEAN_FLOOR ignores water, so a sea bed shows its real depth.
		Predicate<BlockState> solid = Heightmap.Types.OCEAN_FLOOR_WG.isOpaque();
		BlockState defaultBlock = settings.defaultBlock();
		DensityVolume volume = new DensityVolume(sizeX, noise.height(), sizeZ,
				origin + col0 * step, noise.minY(), origin + row0 * step, step, 1, step);
		try (NoiseChunk chunk = new NoiseChunk(source.randomState(), null, settings,
				source.fluidPicker().get(), Blender.empty(), volume)) {
			Aquifer aquifer = chunk.aquifer();
			DensitySampler.Bound finalDensity = chunk.cachingSamplers().get(settings.noiseRouter().finalDensity());
			for (int iz = 0; iz < sizeZ; iz++) {
				for (int ix = 0; ix < sizeX; ix++) {
					int x = volume.blockX(ix), z = volume.blockZ(iz);
					// The density is read one column at a time, as vanilla does. Read over the whole tile
					// at once, it is also computed at every corner of the interpolation cells between
					// the columns: the same values, ten times slower (measured).
					DensityVolume column = new DensityVolume(1, noise.height(), 1, x, noise.minY(), z);
					int ground = level.getMinY();
					try (ScopedDensityBuffer density = finalDensity.sampleVolume(column)) {
						for (int iy = column.sizeY() - 1; iy >= 0; iy--) {
							int y = column.blockY(iy);
							BlockState block = aquifer.computeSubstance(x, y, z, density.get(column.indexUnchecked(0, iy, 0)));
							if (solid.test(block == null ? defaultBlock : block)) {
								ground = y + 1;
								break;
							}
						}
					}
					heights[(row0 + iz) * samples + col0 + ix] = (short) ground;
				}
			}
		}
	}

	/**
	 * Every biome the generator's biome source can place, so the page can say which ones the square does
	 * not hold. The map reads the surface only, and a cave biome can never be met there: each entry says
	 * whether the biome is tagged as underground ({@code c:is_underground}, the tag Fabric API and the
	 * mods that add cave biomes fill). Without that tag in the pack, every biome counts as a surface one.
	 */
	private static JsonArray possibleBiomes(Generator source) {
		List<Holder<Biome>> possible = new ArrayList<>(source.generator().getBiomeSource().possibleBiomes());
		// A set has no order of its own: by name, so two runs write the same file.
		possible.sort((a, b) -> a.getRegisteredName().compareTo(b.getRegisteredName()));
		JsonArray list = new JsonArray();
		for (Holder<Biome> biome : possible) {
			JsonObject entry = new JsonObject();
			entry.addProperty("id", biome.getRegisteredName());
			entry.addProperty("underground", biome.is(UNDERGROUND));
			list.add(entry);
		}
		return list;
	}

	/**
	 * Writes one pass as {@code <name>.json}, {@code heights.bin} and {@code biomes.bin}, the two binary
	 * files prefixed with {@code <name>-<step>-} unless the name is {@code preview}, whose files keep
	 * their first names.
	 */
	private static void write(Path out, String name, Generator source, Grid grid) throws IOException {
		Map<String, Integer> indexOf = new HashMap<>();
		List<Holder<Biome>> biomeList = new ArrayList<>();
		ByteBuffer biomeBytes = ByteBuffer.allocate(grid.biomes().length * 2).order(ByteOrder.LITTLE_ENDIAN);
		for (Holder<Biome> biome : grid.biomes()) {
			Integer index = indexOf.get(biome.getRegisteredName());
			if (index == null) {
				index = biomeList.size();
				indexOf.put(biome.getRegisteredName(), index);
				biomeList.add(biome);
			}
			biomeBytes.putShort((short) (int) index);
		}

		ByteBuffer heightBytes = ByteBuffer.allocate(grid.heights().length * 2).order(ByteOrder.LITTLE_ENDIAN);
		for (short height : grid.heights()) {
			heightBytes.putShort(height);
		}

		ServerLevel level = source.level();
		JsonObject json = new JsonObject();
		json.addProperty("seed", Long.toString(level.getSeed()));
		json.addProperty("samples", grid.samples());
		json.addProperty("step", grid.step());
		json.addProperty("originX", grid.origin());
		json.addProperty("originZ", grid.origin());
		json.addProperty("seaLevel", source.generator().getSeaLevel());
		json.addProperty("minY", level.getMinY());
		json.addProperty("maxY", level.getMaxY());
		JsonArray list = new JsonArray();
		for (Holder<Biome> biome : biomeList) {
			JsonObject entry = new JsonObject();
			entry.addProperty("id", biome.getRegisteredName());
			entry.addProperty("temperature", biome.value().getBaseTemperature());
			list.add(entry);
		}
		json.add("biomes", list);
		json.add("possible", possibleBiomes(source));
		json.addProperty("sampleMillis", grid.millis());

		String prefix = name.equals("preview") ? "" : name + "-" + grid.step() + "-";
		Files.write(out.resolve(prefix + "heights.bin"), heightBytes.array());
		Files.write(out.resolve(prefix + "biomes.bin"), biomeBytes.array());
		// Written last: its presence tells the caller the two binary files are complete.
		Files.writeString(out.resolve(name + ".json"), new GsonBuilder().setPrettyPrinting().create().toJson(json));

		WorldPreview.LOG.info("World preview ({}): {} x {} points every {} blocks, {} biomes, {} ms",
				name, grid.samples(), grid.samples(), grid.step(), biomeList.size(), grid.millis());
	}
}
