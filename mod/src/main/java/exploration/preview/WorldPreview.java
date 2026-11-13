package exploration.preview;

import java.nio.file.Path;

import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Entry point. The mod does nothing in normal play: it only acts when the server is started with
 * {@code -Dworldpreview.out=<folder>}. Then it samples the world generator once the server is up,
 * writes the result into that folder and stops the server.
 */
public final class WorldPreview implements ModInitializer {
	static final Logger LOG = LoggerFactory.getLogger("world-preview");

	@Override
	public void onInitialize() {
		String out = System.getProperty("worldpreview.out");
		if (out == null) {
			return;
		}

		int samples = Integer.getInteger("worldpreview.samples", 512);
		int step = Integer.getInteger("worldpreview.step", 16);
		// Blocks between two points of the last pass: the step itself for the full map, or one of the
		// sketches' steps to stop there.
		int detail = Integer.getInteger("worldpreview.detail", step);

		ServerLifecycleEvents.SERVER_STARTED.register(server -> {
			try {
				Sampler.run(server, Path.of(out), samples, step, detail);
			} catch (Exception e) {
				LOG.error("World preview failed", e);
			} finally {
				// One run, one preview: the caller waits for the process to end.
				server.halt(false);
			}
		});
	}
}
