# Multi-stage build for Java bench (pgjdbc).
# Stage 1 (maven:3.9-eclipse-temurin-21 builder): builds shaded fat jar.
# Stage 2 (eclipse-temurin:21-jre-alpine runtime): only JRE + the jar.
# Final image ~200MB (Alpine JRE + driver jar).

FROM maven:3.9-eclipse-temurin-21 AS builder

WORKDIR /src

COPY benchmarks/drivers/java/pom.xml .
RUN mvn -B -q dependency:go-offline

COPY benchmarks/drivers/java/src ./src
RUN mvn -B -q package -DskipTests

FROM eclipse-temurin:21-jre-alpine

RUN apk add --no-cache postgresql16-client

WORKDIR /app
COPY --from=builder /src/target/bench-java.jar /app/bench-java.jar

VOLUME ["/outputs"]

# G1 GC + headless server-class JIT defaults. -XX:+UseG1GC is implicit
# in Java 21 but we set explicitly for reproducibility.
ENTRYPOINT ["java", "-XX:+UseG1GC", "-Xms256m", "-Xmx2g", "-jar", "/app/bench-java.jar"]
CMD ["--workers", "1", "--conns-per-worker", "1", "--tx-count", "5000", "--reps", "3"]
