package exploration.preview;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * The one way a file reaches the out folder: written beside its place, then moved there in one go,
 * so a reader polling the folder never sees half of one.
 *
 * <p>The order of calls still matters to readers: a {@code .json} that announces {@code .bin} files is
 * written after them. The driver clears {@code *.tmp} before a run, in case a run died between the
 * write and the move.
 */
final class OutFile {
	private OutFile() {
	}

	static void write(Path target, byte[] bytes) throws IOException {
		Path temporary = target.resolveSibling(target.getFileName() + ".tmp");
		try {
			Files.write(temporary, bytes);
			Files.move(temporary, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
		} catch (IOException | RuntimeException e) {
			// A leftover must not sit in the folder as if it were a result.
			try {
				Files.deleteIfExists(temporary);
			} catch (IOException ignored) {
				// The driver clears it before the next run.
			}
			throw e;
		}
	}

	static void write(Path target, String text) throws IOException {
		write(target, text.getBytes(StandardCharsets.UTF_8));
	}
}
