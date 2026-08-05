# bench/http/java — Spring Boot 3 + embedded Tomcat + HikariCP + pgjdbc.

FROM eclipse-temurin:21-jdk AS build
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
        maven \
    && rm -rf /var/lib/apt/lists/*

# Cache Maven deps on its own layer.
COPY bench/http/java/pom.xml ./
RUN mvn -B -q dependency:go-offline || true

COPY bench/http/java/src ./src
RUN mvn -B -q clean package -DskipTests
RUN cp /src/target/bench-http-java.jar /out.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /out.jar /app/app.jar

EXPOSE 8080
# Container-aware heap; reasonable for bench (4G mem limit).
ENV JAVA_OPTS="-XX:MaxRAMPercentage=60 -XX:+UseG1GC"
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
