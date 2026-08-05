# bench/http/go-mongo — net/http (stdlib) + MongoDB (official mongo-driver).
#
# Static binary in scratch — Go's standard recipe. Small final image.

FROM golang:1.23-bookworm AS build
WORKDIR /src
COPY bench/http/go-mongo/go.mod bench/http/go-mongo/go.sum ./
RUN go mod download
COPY bench/http/go-mongo/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
