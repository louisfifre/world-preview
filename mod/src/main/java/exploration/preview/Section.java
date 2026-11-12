package exploration.preview;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ForkJoinPool;
import java.util.stream.IntStream;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.NoiseSettings;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.densityfunction.DensitySampler;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.densityfunction.ScopedDensityBuffer;

/**
 * Vertical cuts through the ground, from the bottom of the world to its top, one block per cell.
 *
 * <p>A cut runs from west to east. Each of its cells is what the generator's density and aquifers
 * give before anything else touches the chunk: rock, air, water or lava. So the noise caves and the
 * underground lakes are there; what later steps of a real chunk add is not (the top layers of earth
 * or sand, carved ravines, ores, trees). Like the map, it reads the generator only: no chunk is
 * generated.
 *
 * <p>The cuts are chosen on the map just sampled, among lines drawn at random from the seed: those
 * that cross the most different ground win, a high point, some sea and some level land. Output:
 * {@code section-<n>.bin}, one byte per cell, row by row from the top of the world down, then
 * {@code section.json}, which lists them.
 */
final class Section {
	/** Blocks along a cut, when the map is that wide. */
	private static final int LENGTH = 2048;
	private static final int CUTS = 4;
	private static final int CANDIDATES = 400;
	/** Columns sampled with one noise chunk. */
	private static final int TILE = 16;

	static final byte AIR = 0, ROCK = 1, WATER = 2, LAVA = 3;

	private Section() {
	}

	/** A line of the grid: its row, its first column, and how varied the ground along it is. */
	private record Line(int row, int col, double score) {
	}

	static void write(Path out, Sampler.Generator source, Sampler.Grid grid, ForkJoinPool pool) throws IOException {
		int points = Math.min(grid.samples(), LENGTH / grid.step());
		int length = points * grid.step();
		NoiseSettings noise = source.noise();
		int sea = source.generator().getSeaLevel();

		JsonArray cuts = new JsonArray();
		int index = 0;
		for (Line line : choose(grid, points, sea, source.level().getSeed())) {
			int x0 = grid.origin() + line.col() * grid.step(), z = grid.origin() + line.row() * grid.step();
			String file = "section-" + index++ + ".bin";
			Files.write(out.resolve(file), cells(source, pool, x0, z, length));
			JsonObject cut = new JsonObject();
			cut.addProperty("file", file);
			cut.addProperty("x", x0);
			cut.addProperty("z", z);
			cuts.add(cut);
		}

		JsonObject json = new JsonObject();
		json.addProperty("length", length);
		json.addProperty("height", noise.height());
		json.addProperty("minY", noise.minY());
		json.addProperty("seaLevel", sea);
		json.add("cuts", cuts);
		// Written last: its presence tells the caller the cuts are complete.
		Files.writeString(out.resolve("section.json"), new GsonBuilder().setPrettyPrinting().create().toJson(json));
		WorldPreview.LOG.info("World preview (section): {} cuts of {} blocks", cuts.size(), length);
	}

	/**
	 * The lines worth cutting. A cut is there to show how the underground follows the ground, so a
	 * line scores by how high it climbs above the sea, and more when it also crosses some sea and some
	 * level land. The draw depends on the seed alone: the same seed gives the same lines, so two runs
	 * with other values are compared on the same places.
	 */
	private static List<Line> choose(Sampler.Grid grid, int points, int sea, long seed) {
		int n = grid.samples();
		short[] heights = grid.heights();
		Random random = new Random(seed);
		List<Line> lines = new ArrayList<>();
		for (int i = 0; i < CANDIDATES; i++) {
			int row = random.nextInt(n), col = random.nextInt(n - points + 1);
			int top = Integer.MIN_VALUE, water = 0, level = 0;
			for (int p = 0; p < points; p++) {
				int h = heights[row * n + col + p];
				top = Math.max(top, h);
				if (h < sea - 2) {
					water++;
				} else if (p > 0 && heights[row * n + col + p - 1] >= sea - 2
						&& Math.abs(h - heights[row * n + col + p - 1]) <= 2) {
					level++;
				}
			}
			double waterShare = (double) water / points, levelShare = (double) level / points;
			double score = (top - sea) + (waterShare >= 0.05 && waterShare <= 0.5 ? 150 : 0)
					+ (levelShare >= 0.2 ? 100 : 0);
			lines.add(new Line(row, col, score));
		}
		lines.sort((a, b) -> Double.compare(b.score(), a.score()));
		// The best ones, but not twice the same place: rows at least a quarter of a cut apart.
		List<Line> kept = new ArrayList<>();
		for (Line line : lines) {
			if (kept.size() < CUTS && kept.stream().noneMatch(k -> Math.abs(k.row() - line.row()) < points / 4)) {
				kept.add(line);
			}
		}
		return kept;
	}

	/** The cells of one cut, sampled the way {@code Sampler.sampleTile} finds the ground: column by column. */
	private static byte[] cells(Sampler.Generator source, ForkJoinPool pool, int x0, int z, int length) {
		NoiseSettings noise = source.noise();
		NoiseGeneratorSettings settings = source.settings();
		BlockState defaultBlock = settings.defaultBlock();
		int height = noise.height();
		byte[] cells = new byte[length * height];
		pool.submit(() -> IntStream.range(0, (length + TILE - 1) / TILE).parallel().forEach(tile -> {
			int first = tile * TILE, size = Math.min(TILE, length - first);
			DensityVolume volume = new DensityVolume(size, height, 1, x0 + first, noise.minY(), z, 1, 1, 1);
			try (NoiseChunk chunk = new NoiseChunk(source.randomState(), null, settings,
					source.fluidPicker().get(), Blender.empty(), volume)) {
				Aquifer aquifer = chunk.aquifer();
				DensitySampler.Bound finalDensity = chunk.cachingSamplers().get(settings.noiseRouter().finalDensity());
				for (int ix = 0; ix < size; ix++) {
					int x = volume.blockX(ix);
					DensityVolume column = new DensityVolume(1, height, 1, x, noise.minY(), z);
					try (ScopedDensityBuffer density = finalDensity.sampleVolume(column)) {
						for (int iy = 0; iy < height; iy++) {
							BlockState block = aquifer.computeSubstance(x, column.blockY(iy), z,
									density.get(column.indexUnchecked(0, iy, 0)));
							if (block == null) {
								block = defaultBlock;
							}
							byte cell = block.is(Blocks.WATER) ? WATER : block.is(Blocks.LAVA) ? LAVA
									: block.isAir() ? AIR : ROCK;
							cells[(height - 1 - iy) * length + first + ix] = cell;
						}
					}
				}
			}
		})).join();
		return cells;
	}
}
