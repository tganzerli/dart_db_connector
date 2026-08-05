package io.github.tganzerli.bench;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;

@RestController
public class BenchController {

    private static final int WORLD_ROWS = 10_000;
    // Virtual thread executor (Java 21+). Cheap parallelism for /queries and /updates.
    private static final Executor VIRTUAL = Executors.newVirtualThreadPerTaskExecutor();

    private final DataSource ds;

    public BenchController(DataSource ds) {
        this.ds = ds;
    }

    @GetMapping(value = "/plaintext", produces = MediaType.TEXT_PLAIN_VALUE)
    public String plaintext() {
        return "Hello, World!";
    }

    @GetMapping("/json")
    public Map<String, String> jsonHello() {
        return Map.of("message", "Hello, World!");
    }

    @GetMapping("/db")
    public Map<String, Integer> db() throws SQLException {
        return selectWorld(ThreadLocalRandom.current().nextInt(1, WORLD_ROWS + 1));
    }

    @GetMapping("/queries")
    public List<Map<String, Integer>> queries(@RequestParam(value = "count", required = false) String countRaw)
            throws ExecutionException, InterruptedException {
        int n = clampCount(countRaw);
        List<CompletableFuture<Map<String, Integer>>> futures = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            futures.add(CompletableFuture.supplyAsync(() -> {
                try {
                    return selectWorld(ThreadLocalRandom.current().nextInt(1, WORLD_ROWS + 1));
                } catch (SQLException e) {
                    throw new RuntimeException(e);
                }
            }, VIRTUAL));
        }
        List<Map<String, Integer>> out = new ArrayList<>(n);
        for (var f : futures) out.add(f.get());
        return out;
    }

    @GetMapping("/updates")
    public List<Map<String, Integer>> updates(@RequestParam(value = "count", required = false) String countRaw)
            throws ExecutionException, InterruptedException {
        int n = clampCount(countRaw);
        List<CompletableFuture<Map<String, Integer>>> futures = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            futures.add(CompletableFuture.supplyAsync(() -> {
                try {
                    int id = ThreadLocalRandom.current().nextInt(1, WORLD_ROWS + 1);
                    int nr = ThreadLocalRandom.current().nextInt(1, WORLD_ROWS + 1);
                    updateWorld(id, nr);
                    Map<String, Integer> m = new HashMap<>(2);
                    m.put("id", id);
                    m.put("randomNumber", nr);
                    return m;
                } catch (SQLException e) {
                    throw new RuntimeException(e);
                }
            }, VIRTUAL));
        }
        List<Map<String, Integer>> out = new ArrayList<>(n);
        for (var f : futures) out.add(f.get());
        return out;
    }

    @GetMapping(value = "/fortunes", produces = MediaType.TEXT_HTML_VALUE)
    public String fortunes() throws SQLException {
        List<int[]> raw = new ArrayList<>(13);
        List<String> messages = new ArrayList<>(13);
        try (Connection conn = ds.getConnection();
             PreparedStatement ps = conn.prepareStatement("SELECT id, message FROM fortune");
             ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                raw.add(new int[]{rs.getInt(1)});
                messages.add(rs.getString(2));
            }
        }
        Integer[] ids = new Integer[raw.size() + 1];
        String[] msgs = new String[raw.size() + 1];
        for (int i = 0; i < raw.size(); i++) {
            ids[i] = raw.get(i)[0];
            msgs[i] = messages.get(i);
        }
        ids[raw.size()] = 0;
        msgs[raw.size()] = "Additional fortune added at request time.";
        // Sort by message ascending.
        Integer[] idx = new Integer[ids.length];
        for (int i = 0; i < ids.length; i++) idx[i] = i;
        Arrays.sort(idx, (a, b) -> msgs[a].compareTo(msgs[b]));

        StringBuilder sb = new StringBuilder(2048);
        sb.append("<!DOCTYPE html><html><head><title>Fortunes</title></head><body>")
          .append("<table><tr><th>id</th><th>message</th></tr>");
        for (int i : idx) {
            sb.append("<tr><td>").append(ids[i]).append("</td><td>")
              .append(htmlEscape(msgs[i])).append("</td></tr>");
        }
        sb.append("</table></body></html>");
        return sb.toString();
    }

    private Map<String, Integer> selectWorld(int id) throws SQLException {
        try (Connection conn = ds.getConnection();
             PreparedStatement ps = conn.prepareStatement(
                     "SELECT id, randomnumber FROM world WHERE id = ?")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                rs.next();
                Map<String, Integer> m = new HashMap<>(2);
                m.put("id", rs.getInt(1));
                m.put("randomNumber", rs.getInt(2));
                return m;
            }
        }
    }

    private void updateWorld(int id, int newRand) throws SQLException {
        try (Connection conn = ds.getConnection()) {
            conn.setAutoCommit(false);
            try (PreparedStatement sel = conn.prepareStatement(
                    "SELECT id, randomnumber FROM world WHERE id = ?")) {
                sel.setInt(1, id);
                try (ResultSet rs = sel.executeQuery()) {
                    rs.next();
                }
            }
            try (PreparedStatement upd = conn.prepareStatement(
                    "UPDATE world SET randomnumber = ? WHERE id = ?")) {
                upd.setInt(1, newRand);
                upd.setInt(2, id);
                upd.executeUpdate();
            }
            conn.commit();
        }
    }

    private static int clampCount(String raw) {
        if (raw == null) return 1;
        try {
            int v = Integer.parseInt(raw);
            if (v < 1) return 1;
            if (v > 500) return 500;
            return v;
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    private static String htmlEscape(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&' -> sb.append("&amp;");
                case '<' -> sb.append("&lt;");
                case '>' -> sb.append("&gt;");
                case '"' -> sb.append("&quot;");
                case '\'' -> sb.append("&#39;");
                default -> sb.append(c);
            }
        }
        return sb.toString();
    }
}
