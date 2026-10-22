package fixtures;

import java.util.List;

/**
 * Source of the committed `.class` and `.jar` fixtures used by the Java
 * developer tool tests.
 *
 * Regenerate with:
 *
 * <pre>
 * javac --release 17 -g:none -d build/classes src/fixtures/Greeting.java
 * jar --create --file greeting.jar --manifest src/manifest.mf -C build/classes .
 * </pre>
 *
 * `--release 17` pins the class-file major version to 61 so the inspector's
 * "Java 17" mapping is asserted against a real Java 17 executable format.
 */
public final class Greeting {
    public static final String PREFIX = "hi";

    private final String name;

    public Greeting(String name) {
        this.name = name;
    }

    public String greet(int times) {
        final StringBuilder builder = new StringBuilder();
        for (int i = 0; i < times; i++) {
            builder.append(PREFIX).append(' ').append(name);
        }
        return builder.toString();
    }

    public List<String> tags(String... values) {
        return List.of(values);
    }

    public static void main(String[] args) {
        System.out.println(new Greeting("world").greet(1));
    }
}
