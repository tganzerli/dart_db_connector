package io.github.tganzerli.bench;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration;
import org.springframework.context.annotation.Bean;

import javax.sql.DataSource;

@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
public class Application {

    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }

    @Bean
    public DataSource dataSource() {
        var cfg = new HikariConfig();
        var host = env("POSTGRES_HOST", "postgres");
        var port = env("POSTGRES_PORT", "5432");
        var db = env("POSTGRES_DB", "teste");
        var user = env("POSTGRES_USER", "postgres");
        var password = env("POSTGRES_PASSWORD", "123");
        int poolSize;
        try {
            poolSize = Integer.parseInt(env("POOL_SIZE", "64"));
        } catch (NumberFormatException e) {
            poolSize = 64;
        }

        cfg.setJdbcUrl(String.format("jdbc:postgresql://%s:%s/%s", host, port, db));
        cfg.setUsername(user);
        cfg.setPassword(password);
        cfg.setMaximumPoolSize(poolSize);
        cfg.setMinimumIdle(poolSize);
        cfg.setAutoCommit(true);
        // No connection test query — wastes one round-trip per acquire.
        cfg.setConnectionTestQuery(null);
        cfg.setPoolName("bench-http-java");

        System.out.printf("[java] HikariCP pool ready (size=%d)%n", poolSize);
        return new HikariDataSource(cfg);
    }

    private static String env(String k, String def) {
        var v = System.getenv(k);
        return (v != null && !v.isEmpty()) ? v : def;
    }
}
