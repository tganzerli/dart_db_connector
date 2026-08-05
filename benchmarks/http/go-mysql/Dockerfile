# bench/http/go-mysql — net/http (stdlib) + database/sql + go-sql-driver/mysql.
#
# Static binary in scratch — Go's standard recipe. ~10 MB final image.

FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY bench/http/go-mysql/go.mod bench/http/go-mysql/go.sum ./
RUN go mod download
COPY bench/http/go-mysql/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
