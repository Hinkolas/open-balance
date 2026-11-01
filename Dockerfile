FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
COPY migrations ./migrations
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /server /server
EXPOSE 8080
CMD ["/server", "serve"]
