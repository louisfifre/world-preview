package exploration.preview;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.Biome;

/**
 * What the run is doing, for the page, which otherwise only learns of a pass once its files land.
 *
 * <p>{@code progress.json} says which pass is under way and how many of its tiles are done: the page
 * shows the step under way as it starts, with a real share, instead of ticking it once it is over. Its
 * presence alone says the game has started. During the map's own pass, the points already known are
 * written too ({@code partial-heights.bin}, {@code partial-biomes.bin}, then {@code partial.json}), so
 * the map fills in on screen tile by tile instead of appearing at the end.
 *
 * <p>Everything is written from a thread of its own, every half second, so the sampling threads never
 * wait on the disk. Each file is written beside its place and moved there in one go: the page never reads
 * half a file. A move fails while the page's server is reading the old file; the next tick tries again.
 */
final class Progress implements AutoCloseable {
	/** A point of the map's pass not sampled yet, in {@code partial-biomes.bin}. */
	static final short UNKNOWN = -1;

	/** The map's pass under way: the arrays it fills, read as they are, and the biomes it numbers its points by. */
	record Partial(int samples, int step, int origin, short[] heights, short[] biomes, List<Holder<Biome>> biomeList,
			JsonObject world) {
	}

	private final Path out;
	private final ScheduledExecutorService writer;
	private final AtomicInteger done = new AtomicInteger();
	private volatile String pass = "";
	private volatile int step;
	private volatile int total;
	private volatile Partial partial;
	private String written = "";
	private int partialWritten = -1;
	private long partialAt;

	Progress(Path out) {
		this.out = out;
		this.writer = Executors.newSingleThreadScheduledExecutor(runnable -> {
			Thread thread = new Thread(runnable, "world-preview progress");
			thread.setDaemon(true);
			return thread;
		});
		writer.scheduleWithFixedDelay(this::write, 500, 500, TimeUnit.MILLISECONDS);
	}

	/** A pass starts: {@code sketch} or {@code map} with its step and its tiles, or {@code extras} (no tiles). */
	void begin(String pass, int step, int total, Partial partial) {
		this.done.set(0);
		this.step = step;
		this.total = total;
		this.partial = partial;
		this.pass = pass;
		write();
	}

	void tileDone() {
		done.incrementAndGet();
	}

	private synchronized void write() {
		JsonObject json = new JsonObject();
		json.addProperty("pass", pass);
		json.addProperty("step", step);
		json.addProperty("done", done.get());
		json.addProperty("total", total);
		String text = json.toString();
		if (!text.equals(written) && replace(out.resolve("progress.json"), text.getBytes(StandardCharsets.UTF_8))) {
			written = text;
		}
		writePartial();
	}

	/**
	 * The points known so far, once a second at most: a wide map's files weigh megabytes, and the page
	 * redraws the whole map each time.
	 */
	private void writePartial() {
		Partial p = partial;
		int now = done.get();
		if (p == null || now == partialWritten || System.nanoTime() - partialAt < 1_000_000_000L) {
			return;
		}
		ByteBuffer heights = ByteBuffer.allocate(p.heights().length * 2).order(ByteOrder.LITTLE_ENDIAN);
		ByteBuffer biomes = ByteBuffer.allocate(p.biomes().length * 2).order(ByteOrder.LITTLE_ENDIAN);
		// The sampling threads write these arrays meanwhile, without a lock: a point read halfway is a point
		// of a draft, which the next writing and then the map itself replace.
		for (short height : p.heights()) {
			heights.putShort(height);
		}
		for (short biome : p.biomes()) {
			biomes.putShort(biome);
		}
		JsonObject json = p.world().deepCopy();
		json.addProperty("done", now);
		json.addProperty("total", total);
		// The json last: its presence tells the page the two binary files beside it are whole.
		if (replace(out.resolve("partial-heights.bin"), heights.array())
				&& replace(out.resolve("partial-biomes.bin"), biomes.array())
				&& replace(out.resolve("partial.json"), json.toString().getBytes(StandardCharsets.UTF_8))) {
			partialWritten = now;
			partialAt = System.nanoTime();
		}
	}

	/** The description of a map the page draws, as in {@code preview.json}, with every possible biome as its list. */
	static JsonObject world(Sampler.Generator source, int samples, int step, int origin, List<Holder<Biome>> biomeList) {
		JsonObject json = new JsonObject();
		json.addProperty("samples", samples);
		json.addProperty("step", step);
		json.addProperty("originX", origin);
		json.addProperty("originZ", origin);
		json.addProperty("seaLevel", source.generator().getSeaLevel());
		json.addProperty("minY", source.level().getMinY());
		json.addProperty("maxY", source.level().getMaxY());
		JsonArray list = new JsonArray();
		for (Holder<Biome> biome : biomeList) {
			JsonObject entry = new JsonObject();
			entry.addProperty("id", biome.getRegisteredName());
			entry.addProperty("temperature", biome.value().getBaseTemperature());
			list.add(entry);
		}
		json.add("biomes", list);
		return json;
	}

	private static boolean replace(Path target, byte[] bytes) {
		Path temporary = target.resolveSibling(target.getFileName() + ".tmp");
		try {
			Files.write(temporary, bytes);
			Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
			return true;
		} catch (IOException e) {
			return false;
		}
	}

	@Override
	public void close() {
		writer.shutdownNow();
		try {
			writer.awaitTermination(2, TimeUnit.SECONDS);
		} catch (InterruptedException e) {
			Thread.currentThread().interrupt();
		}
	}
}
