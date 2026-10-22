package fixtures;

import java.nio.file.Files;
import java.nio.file.Path;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.ConstantDynamic;
import jdk.internal.org.objectweb.asm.Handle;
import jdk.internal.org.objectweb.asm.MethodVisitor;
import static jdk.internal.org.objectweb.asm.Opcodes.*;

/**
 * Generates and actually loads a Java 17 class using CONSTANT_Dynamic (javac
 * does not normally emit that tag). JDK's bundled ASM is used only for fixture
 * generation, with no downloaded build dependency or product dependency.
 * Compile/run this helper with:
 * --add-exports java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED
 * Pass the output path dynamic.class.bin as its only argument.
 */
public final class GenerateDynamicFixture extends ClassLoader {
    public static void main(String[] args) throws Exception {
        ClassWriter writer = new ClassWriter(0);
        writer.visit(V17, ACC_PUBLIC | ACC_FINAL, "fixtures/DynamicFixture", null,
                "java/lang/Object", null);
        MethodVisitor method = writer.visitMethod(ACC_PUBLIC | ACC_STATIC,
                "value", "()Ljava/lang/String;", null, null);
        method.visitCode();
        Handle bootstrap = new Handle(H_INVOKESTATIC,
                "java/lang/invoke/ConstantBootstraps", "nullConstant",
                "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/Object;",
                false);
        method.visitLdcInsn(new ConstantDynamic("value", "Ljava/lang/String;", bootstrap));
        method.visitInsn(ARETURN);
        method.visitMaxs(1, 0);
        method.visitEnd();
        writer.visitEnd();
        byte[] bytes = writer.toByteArray();
        Class<?> generated = new GenerateDynamicFixture().defineClass(
                "fixtures.DynamicFixture", bytes, 0, bytes.length);
        if (generated.getMethod("value").invoke(null) != null) {
            throw new AssertionError("Dynamic null constant was not loaded");
        }
        Files.write(Path.of(args[0]), bytes);
        System.out.println("CONSTANT_Dynamic fixture: loaded and executed on Java "
                + Runtime.version().feature());
    }
}
