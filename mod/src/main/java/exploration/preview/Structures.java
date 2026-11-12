package exploration.preview;

import java.io.IOException;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import net.minecraft.core.Holder;
import net.minecraft.core.RegistryAccess;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.biome.Climate;
import net.minecraft.world.level.chunk.ChunkGeneratorStructureState;
import net.minecraft.world.level.levelgen.LegacyRandomSource;
import net.minecraft.world.level.levelgen.WorldgenRandom;
import net.minecraft.world.level.levelgen.densityfunction.SamplerContext;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.levelgen.structure.StructureSet;
import net.minecraft.world.level.levelgen.structure.StructureStart;
import net.minecraft.world.level.levelgen.structure.placement.ConcentricRingsStructurePlacement;
import net.minecraft.world.level.levelgen.structure.placement.RandomSpreadStructurePlacement;
import net.minecraft.world.level.levelgen.structure.placement.StructurePlacement;
import net.minecraft.world.level.levelgen.structure.structures.JigsawStructure;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructureTemplateManager;

/**
 * Where structures would start over the sampled square, for every structure set of the overworld
 * generator.
 *
 * <p>It asks the generator the questions {@code ChunkGenerator.createStructures} asks when a chunk
 * reaches its structure starts, and nothing else: which chunks the set's placement picks (its
 * random-spread regions or its concentric rings, then its frequency and its exclusion zone), which
 * structure of the set is tried there, and whether that structure finds a valid generation point
 * and has at least one piece. {@code createStructures} needs a chunk only to store the start it
 * finds and to skip a chunk that already holds one; here there is no chunk, so nothing is stored and
 * nothing is skipped. {@code /locate} is not used: it goes through the structure manager, which
 * loads chunks to read the starts they hold. So, like the map, it reads the generator only.
 *
 * <p>A start is where a structure begins, not all it covers: a village spreads over several chunks
 * around its point. What a later step of a real chunk may still change (a structure's pieces that
 * cannot be placed, a mod that removes a structure after its start) is not known here. Output:
 * {@code structures.json}, the structures of every set and one row per start,
 * {@code [index into structures, x, z]} in blocks, at the generation point the structure found.
 */
final class Structures {
	/** The depth of a jigsaw structure, private in the game, or null when it cannot be read. */
	private static final Field JIGSAW_DEPTH = jigsawDepth();

	private Structures() {
	}

	/**
	 * One structure of one set, as listed in the output. The step is the generation step the structure
	 * declares (underground_structures, surface_structures...): the only thing the generator says of
	 * whether it is built under the ground, so the page can tell a mineshaft from a village.
	 */
	private record Entry(String id, String set, String step) {
	}

	/** A chunk a set's placement picked, to be tried. */
	private record Candidate(Holder<StructureSet> set, int chunkX, int chunkZ) {
	}

	/** What every try needs. */
	private record Context(Sampler.Generator source, ChunkGeneratorStructureState state, RegistryAccess access,
			StructureTemplateManager templates, Map<Entry, Integer> indexOf) {
	}

	private static Entry entryOf(StructureSet.StructureSelectionEntry entry, Holder<StructureSet> set) {
		return new Entry(entry.structure().getRegisteredName(), set.getRegisteredName(),
				entry.structure().value().step().getSerializedName());
	}

	static void write(MinecraftServer server, Path out, Sampler.Generator source, Sampler.Grid grid,
			ForkJoinPool pool) throws IOException {
		long started = System.nanoTime();
		ChunkGeneratorStructureState state = source.level().getChunkSource().getGeneratorState();
		int min = grid.origin(), max = grid.origin() + grid.samples() * grid.step();
		int chunk0 = Math.floorDiv(min, 16), chunk1 = Math.floorDiv(max - 1, 16);

		List<Entry> entries = new ArrayList<>();
		Map<Entry, Integer> indexOf = new HashMap<>();
		List<Candidate> candidates = new ArrayList<>();
		// A world made with structures off creates no start at all: the chunk step that would is skipped.
		boolean enabled = server.getWorldGenSettings().options().generateStructures();
		for (Holder<StructureSet> set : enabled ? state.possibleStructureSets() : List.<Holder<StructureSet>>of()) {
			for (StructureSet.StructureSelectionEntry entry : set.value().structures()) {
				Entry e = entryOf(entry, set);
				if (!indexOf.containsKey(e)) {
					indexOf.put(e, entries.size());
					entries.add(e);
				}
			}
			candidates(state, set, chunk0, chunk1, candidates);
		}

		Context context = new Context(source, state, server.registryAccess(), server.getStructureTemplateManager(),
				indexOf);
		int[][] found = new int[candidates.size()][];
		boolean[] failed = new boolean[candidates.size()];
		// One worker per thread, each taking the next chunk. A parallel stream over the list would cut
		// it into a few long runs, and the costly sets, whose chunks follow each other in the list,
		// would land on one or two threads (measured on a square of 8192: 10 s instead of 6).
		AtomicInteger next = new AtomicInteger();
		pool.submit(() -> IntStream.range(0, pool.getParallelism()).parallel().forEach(worker -> {
			for (int i = next.getAndIncrement(); i < candidates.size(); i = next.getAndIncrement()) {
				try {
					found[i] = tryChunk(context, candidates.get(i));
				} catch (RuntimeException e) {
					failed[i] = true;
				}
			}
		})).join();
		// Some caches of the game, those of the structure templates among them, are plain maps that two
		// threads filling at once can break (seen once in a run, as a ConcurrentModificationException).
		// The chunks that failed are tried again one at a time, once those caches are filled.
		int failures = 0;
		for (int i = 0; i < candidates.size(); i++) {
			if (failed[i]) {
				Candidate candidate = candidates.get(i);
				try {
					found[i] = tryChunk(context, candidate);
				} catch (RuntimeException e) {
					// A structure of some mod that fails here is left out rather than losing the others.
					if (failures++ == 0) {
						WorldPreview.LOG.warn("World preview (structures): {} at chunk {} {} left out",
								candidate.set().getRegisteredName(), candidate.chunkX(), candidate.chunkZ(), e);
					}
				}
			}
		}

		JsonArray list = new JsonArray();
		for (Entry e : entries) {
			JsonObject entry = new JsonObject();
			entry.addProperty("id", e.id());
			entry.addProperty("set", e.set());
			entry.addProperty("step", e.step());
			list.add(entry);
		}
		JsonArray points = new JsonArray();
		for (int[] point : found) {
			// The generation point may lie a little outside its chunk, so outside the square at its edge.
			if (point != null && point[1] >= min && point[1] < max && point[2] >= min && point[2] < max) {
				JsonArray row = new JsonArray();
				row.add(point[0]);
				row.add(point[1]);
				row.add(point[2]);
				points.add(row);
			}
		}
		JsonObject json = new JsonObject();
		json.add("structures", list);
		json.add("points", points);
		Files.writeString(out.resolve("structures.json"), new GsonBuilder().create().toJson(json));
		WorldPreview.LOG.info("World preview (structures): {} starts of {} structures, {} chunks tried, {} left out, {} ms",
				points.size(), entries.size(), candidates.size(), failures, (System.nanoTime() - started) / 1_000_000);
	}

	/**
	 * The chunks of the square the set's placement picks, its own filters included. A random spread
	 * has one possible chunk per region of {@code spacing} chunks, so only those are asked; the rings
	 * are a list the generator state already holds. Any other placement, which a mod may bring, is
	 * asked about every chunk of the square: slower, but it needs nothing known of its rule.
	 */
	private static void candidates(ChunkGeneratorStructureState state, Holder<StructureSet> set, int chunk0,
			int chunk1, List<Candidate> into) {
		StructurePlacement placement = set.value().placement();
		if (placement instanceof RandomSpreadStructurePlacement spread) {
			int spacing = spread.spacing();
			for (int rz = Math.floorDiv(chunk0, spacing); rz <= Math.floorDiv(chunk1, spacing); rz++) {
				for (int rx = Math.floorDiv(chunk0, spacing); rx <= Math.floorDiv(chunk1, spacing); rx++) {
					ChunkPos pos = spread.getPotentialStructureChunk(state.getLevelSeed(), rx * spacing, rz * spacing);
					add(state, set, placement, pos.x(), pos.z(), chunk0, chunk1, into);
				}
			}
		} else if (placement instanceof ConcentricRingsStructurePlacement rings) {
			for (ChunkPos pos : state.getRingPositionsFor(rings)) {
				add(state, set, placement, pos.x(), pos.z(), chunk0, chunk1, into);
			}
		} else {
			WorldPreview.LOG.info("World preview (structures): {} has a placement of its own, every chunk asked",
					set.getRegisteredName());
			for (int z = chunk0; z <= chunk1; z++) {
				for (int x = chunk0; x <= chunk1; x++) {
					add(state, set, placement, x, z, chunk0, chunk1, into);
				}
			}
		}
	}

	private static void add(ChunkGeneratorStructureState state, Holder<StructureSet> set, StructurePlacement placement,
			int x, int z, int chunk0, int chunk1, List<Candidate> into) {
		// isStructureChunk asks the placement again, then its frequency and its exclusion zone.
		if (x >= chunk0 && x <= chunk1 && z >= chunk0 && z <= chunk1 && placement.isStructureChunk(state, x, z)) {
			into.add(new Candidate(set, x, z));
		}
	}

	/**
	 * The structure of the set that starts in this chunk, as {@code [index, x, z]}, or null. The same
	 * order as {@code createStructures}: a set of one structure tries it; a weighted set draws one with
	 * a random seeded by the chunk, and when that one is not valid there, draws again among the others.
	 */
	private static int[] tryChunk(Context context, Candidate candidate) {
		ChunkPos pos = new ChunkPos(candidate.chunkX(), candidate.chunkZ());
		ChunkGeneratorStructureState state = context.state();
		// One per chunk, with its caches, as createStructures makes it.
		Climate.Sampler climate = state.randomState().createClimateSampler(SamplerContext.builder().enableCaches().build());
		List<StructureSet.StructureSelectionEntry> entries = candidate.set().value().structures();
		if (entries.size() == 1) {
			return tryStructure(context, candidate, entries.get(0), pos, climate);
		}
		List<StructureSet.StructureSelectionEntry> left = new ArrayList<>(entries);
		WorldgenRandom random = new WorldgenRandom(new LegacyRandomSource(0L));
		random.setLargeFeatureSeed(state.getLevelSeed(), pos.x(), pos.z());
		int total = 0;
		for (StructureSet.StructureSelectionEntry entry : left) {
			total += entry.weight();
		}
		while (!left.isEmpty()) {
			int draw = random.nextInt(total), k = 0;
			for (StructureSet.StructureSelectionEntry entry : left) {
				draw -= entry.weight();
				if (draw < 0) {
					break;
				}
				k++;
			}
			StructureSet.StructureSelectionEntry entry = left.get(k);
			int[] point = tryStructure(context, candidate, entry, pos, climate);
			if (point != null) {
				return point;
			}
			left.remove(k);
			total -= entry.weight();
		}
		return null;
	}

	/**
	 * {@code Structure.generate}, step by step, to keep the generation point it finds: the point and
	 * its biome check, then the pieces, a start with none being no start. References are 0, as in a
	 * chunk that holds no start yet.
	 */
	private static int[] tryStructure(Context context, Candidate candidate, StructureSet.StructureSelectionEntry entry,
			ChunkPos pos, Climate.Sampler climate) {
		Structure structure = entry.structure().value();
		Sampler.Generator source = context.source();
		Structure.GenerationContext generation = new Structure.GenerationContext(context.access(), source.generator(),
				source.generator().getBiomeSource(), climate, context.state().randomState(), context.templates(),
				context.state().getLevelSeed(), pos, source.level(), structure.biomes()::contains);
		return structure.findValidGenerationPoint(generation)
				.filter(stub -> hasStartPiece(structure)
						|| new StructureStart(structure, pos, 0, stub.getPiecesBuilder().build()).isValid())
				.map(stub -> new int[] {
						context.indexOf().get(entryOf(entry, candidate.set())),
						stub.position().getX(), stub.position().getZ() })
				.orElse(null);
	}

	/**
	 * Whether the structure's pieces are sure to hold at least its start piece, so that building them
	 * cannot change the answer. Building them is most of the cost: a village lays out every house and
	 * street (measured on a square of 8192: the same file, in 0.8 s instead of 2.5 once the templates
	 * are loaded). A jigsaw structure deeper than 0 always hands its start piece to the builder first,
	 * both in the game's {@code JigsawPlacement} and in Lithostitched's generator, which replaces it in
	 * packs that have Lithostitched; at depth 0 the game's builds nothing, so those are built. Any
	 * other structure is built as {@code Structure.generate} does.
	 */
	private static boolean hasStartPiece(Structure structure) {
		if (!(structure instanceof JigsawStructure) || JIGSAW_DEPTH == null) {
			return false;
		}
		try {
			return JIGSAW_DEPTH.getInt(structure) > 0;
		} catch (IllegalAccessException e) {
			return false;
		}
	}

	private static Field jigsawDepth() {
		try {
			Field field = JigsawStructure.class.getDeclaredField("maxDepth");
			field.setAccessible(true);
			return field;
		} catch (ReflectiveOperationException | RuntimeException e) {
			WorldPreview.LOG.warn("World preview (structures): the depth of jigsaw structures cannot be read, "
					+ "their pieces are built", e);
			return null;
		}
	}
}
