
#!/usr/bin/env bash

set -u

PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
ALPINE_IMAGE="alpine:3.22"

# Use the project's Docker Compose wrapper when available.
if [ -x "./bin/docker-compose" ]; then
    compose=(./bin/docker-compose)
else
    compose=(docker compose)
fi

to_gb() {
    awk -v bytes="$1" 'BEGIN { printf "%.3f GB", bytes / 1000000000 }'
}

CONTAINER_BYTES=0
VOLUME_BYTES=0
IMAGE_BYTES=0
CONTAINER_COUNT=0
VOLUME_COUNT=0
NETWORK_COUNT=0
IMAGE_COUNT=0
IMAGE_IDS=""

echo "Calculating Docker disk usage for: $PROJECT"
echo

# Containers: writable layers, including stopped project containers.
CONTAINERS=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")

if [ -n "$CONTAINERS" ]; then
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        size=$(docker inspect --size --format '{{.SizeRw}}' "$cid" 2>/dev/null)
        size=${size:-0}
        CONTAINER_BYTES=$((CONTAINER_BYTES + size))
        CONTAINER_COUNT=$((CONTAINER_COUNT + 1))

        img=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)
        if [ -n "$img" ] && ! printf '%s\n' "$IMAGE_IDS" | grep -Fxq "$img"; then
            IMAGE_IDS="${IMAGE_IDS}${img}"$'\n'
        fi
    done <<< "$CONTAINERS"
fi

# Volumes: inspect only volumes labelled for this Compose project.
VOLUMES=$(docker volume ls -q \
    --filter "label=com.docker.compose.project=$PROJECT")

if [ -n "$VOLUMES" ]; then
    while IFS= read -r vol; do
        [ -z "$vol" ] && continue
        echo "Measuring volume: $vol"

        kb=$(docker run --rm \
            -v "$vol:/data:ro" \
            "$ALPINE_IMAGE" sh -c 'du -sk /data 2>/dev/null | cut -f1' \
            2>/dev/null)
        kb=${kb:-0}

        VOLUME_BYTES=$((VOLUME_BYTES + kb * 1024))
        VOLUME_COUNT=$((VOLUME_COUNT + 1))
    done <<< "$VOLUMES"
fi

# Images: sum each unique image used by project containers.
if [ -n "$IMAGE_IDS" ]; then
    while IFS= read -r img; do
        [ -z "$img" ] && continue
        size=$(docker image inspect --format '{{.Size}}' "$img" 2>/dev/null)
        if [ -n "$size" ]; then
            IMAGE_BYTES=$((IMAGE_BYTES + size))
            IMAGE_COUNT=$((IMAGE_COUNT + 1))
        fi
    done <<< "$IMAGE_IDS"
fi

# Networks have metadata, but no useful per-network disk-size metric.
NETWORK_COUNT=$(docker network ls -q \
    --filter "label=com.docker.compose.project=$PROJECT" | wc -l | tr -d ' ')

TOTAL_BYTES=$((CONTAINER_BYTES + VOLUME_BYTES + IMAGE_BYTES))

echo
echo "Docker disk usage: $PROJECT"
echo "----------------------------------------"
printf "%-24s %s (%s containers)\n" \
    "Container writable:" "$(to_gb "$CONTAINER_BYTES")" "$CONTAINER_COUNT"
printf "%-24s %s (%s volumes)\n" \
    "Volume data:" "$(to_gb "$VOLUME_BYTES")" "$VOLUME_COUNT"
printf "%-24s %s (%s images)\n" \
    "Image sizes:" "$(to_gb "$IMAGE_BYTES")" "$IMAGE_COUNT"
printf "%-24s %s networks (size not reported)\n" \
    "Networks:" "$NETWORK_COUNT"
echo "----------------------------------------"
printf "%-24s %s\n" "Estimated total:" "$(to_gb "$TOTAL_BYTES")"
echo
echo "Note: Image sizes can include layers shared with other projects."
echo "Bind-mounted host files and Docker build cache are not included."